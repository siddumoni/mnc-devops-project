#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
# Jenkins Master Bootstrap Script
# Runs once on first boot. Installs and configures:
#   Java 17, Jenkins, Maven 3.9, Docker, kubectl, AWS CLI v2, SonarQube
#
# Note: This takes 5-8 minutes to complete.
# Check progress: sudo tail -f /var/log/jenkins-setup.log
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail
exec > >(tee /var/log/jenkins-setup.log) 2>&1

echo "=== [1/8] System update ==="
dnf update -y
dnf install -y git curl wget unzip jq

# ─────────────────────────────────────────────
# Java 17 (Jenkins and Maven both need it)
# ─────────────────────────────────────────────
echo "=== [2/8] Installing Java 17 ==="
dnf install -y java-17-amazon-corretto-headless
java -version

# ─────────────────────────────────────────────
# Jenkins
# ─────────────────────────────────────────────
echo "=== [3/8] Installing Jenkins ==="
wget -O /etc/yum.repos.d/jenkins.repo https://pkg.jenkins.io/redhat-stable/jenkins.repo
rpm --import https://pkg.jenkins.io/redhat-stable/jenkins.io-2023.key
dnf install -y jenkins

# Mount the data EBS volume for JENKINS_HOME
# This ensures build history survives instance replacement
mkfs -t xfs /dev/xvdf || true  # 'true' so it doesn't fail if already formatted
mkdir -p /var/lib/jenkins
echo "/dev/xvdf /var/lib/jenkins xfs defaults,nofail 0 2" >> /etc/fstab
mount -a

chown -R jenkins:jenkins /var/lib/jenkins

systemctl enable jenkins
systemctl start jenkins

# Wait for Jenkins to be ready before continuing
echo "Waiting for Jenkins to start..."
for i in $(seq 1 30); do
  if curl -sf http://localhost:8080/login > /dev/null 2>&1; then
    echo "Jenkins is up!"
    break
  fi
  sleep 10
done

# Save initial admin password to SSM Parameter Store
INITIAL_PASSWORD=$(cat /var/lib/jenkins/secrets/initialAdminPassword 2>/dev/null || echo "not-ready")
aws ssm put-parameter \
  --name "/${project_name}/jenkins/initial-password" \
  --value "$INITIAL_PASSWORD" \
  --type "SecureString" \
  --overwrite \
  --region "${aws_region}" || true

# ─────────────────────────────────────────────
# Maven 3.9
# ─────────────────────────────────────────────
echo "=== [4/8] Installing Maven 3.9 ==="
MAVEN_VERSION="3.9.6"
wget -q "https://archive.apache.org/dist/maven/maven-3/$${MAVEN_VERSION}/binaries/apache-maven-$${MAVEN_VERSION}-bin.tar.gz" \
  -O /tmp/maven.tar.gz
tar -xzf /tmp/maven.tar.gz -C /opt/
ln -sf /opt/apache-maven-$${MAVEN_VERSION}/bin/mvn /usr/local/bin/mvn
mvn -version

# ─────────────────────────────────────────────
# Docker (for building images in pipeline)
# ─────────────────────────────────────────────
echo "=== [5/8] Installing Docker ==="
dnf install -y docker
systemctl enable docker
systemctl start docker

# Add jenkins user to docker group so it can run docker commands
usermod -aG docker jenkins

# ─────────────────────────────────────────────
# kubectl
# ─────────────────────────────────────────────
echo "=== [6/8] Installing kubectl ==="
KUBECTL_VERSION=$(curl -L -s https://dl.k8s.io/release/stable.txt)
curl -LO "https://dl.k8s.io/release/$${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
chmod +x kubectl
mv kubectl /usr/local/bin/
kubectl version --client

# Pre-configure kubectl for the EKS cluster so Jenkins can deploy immediately
aws eks update-kubeconfig \
  --region "${aws_region}" \
  --name "${cluster_name}" \
  --kubeconfig /var/lib/jenkins/.kube/config || true

mkdir -p /var/lib/jenkins/.kube
chown -R jenkins:jenkins /var/lib/jenkins/.kube

# ─────────────────────────────────────────────
# AWS CLI v2
# ─────────────────────────────────────────────
echo "=== [7/8] Installing AWS CLI v2 ==="
curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip -q awscliv2.zip
./aws/install --update
aws --version

# ─────────────────────────────────────────────
# SonarQube Community (runs as a Docker container)
# Port 9000 — Jenkins will talk to it via localhost
# ─────────────────────────────────────────────
echo "=== [8/8] Starting SonarQube via Docker ==="

# SonarQube needs vm.max_map_count increased
echo "vm.max_map_count=262144" >> /etc/sysctl.conf
sysctl -w vm.max_map_count=262144

# Create persistent volumes for SonarQube data
mkdir -p /opt/sonarqube/{data,extensions,logs}
chown -R 1000:1000 /opt/sonarqube

docker run -d \
  --name sonarqube \
  --restart always \
  -p ${sonarqube_port}:9000 \
  -e SONAR_ES_BOOTSTRAP_CHECKS_DISABLE=true \
  -v /opt/sonarqube/data:/opt/sonarqube/data \
  -v /opt/sonarqube/extensions:/opt/sonarqube/extensions \
  -v /opt/sonarqube/logs:/opt/sonarqube/logs \
  sonarqube:community

echo ""
echo "=== ✅ Jenkins setup complete! ==="
echo ""
echo "Jenkins URL  : http://$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4):8080"
echo "SonarQube URL: http://$(curl -s http://169.254.169.254/latest/meta-data/local-ipv4):${sonarqube_port}"
echo ""
echo "Initial Jenkins password stored in SSM: /${project_name}/jenkins/initial-password"
echo "SonarQube default login: admin / admin (change immediately!)"
echo ""
echo "Next steps:"
echo "  1. Open Jenkins, install recommended plugins + Pipeline + SonarQube Scanner"
echo "  2. Add GitHub credentials (username/token) as Jenkins credentials"
echo "  3. Configure SonarQube server in Jenkins → Manage Jenkins → Configure System"
echo "  4. Add SonarQube token in Jenkins credentials"
