// src/App.jsx
// Simple React frontend that talks to the Spring Boot backend.
// In a real MNC app this would be much larger — but this
// demonstrates the pattern cleanly.

import { useState, useEffect } from 'react';

const API_BASE = process.env.REACT_APP_API_URL || 'http://localhost:8080';

function App() {
  const [products, setProducts] = useState([]);
  const [loading, setLoading]   = useState(true);
  const [error, setError]       = useState(null);
  const [newProduct, setNewProduct] = useState({ name: '', description: '', price: '', stockQuantity: '' });

  useEffect(() => {
    fetchProducts();
  }, []);

  const fetchProducts = async () => {
    try {
      setLoading(true);
      const res = await fetch(`${API_BASE}/api/products`);
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      setProducts(data);
    } catch (err) {
      setError(err.message);
    } finally {
      setLoading(false);
    }
  };

  const handleCreate = async (e) => {
    e.preventDefault();
    try {
      const res = await fetch(`${API_BASE}/api/products`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ ...newProduct, price: parseFloat(newProduct.price), stockQuantity: parseInt(newProduct.stockQuantity) })
      });
      if (!res.ok) throw new Error('Failed to create product');
      setNewProduct({ name: '', description: '', price: '', stockQuantity: '' });
      fetchProducts();
    } catch (err) {
      setError(err.message);
    }
  };

  const handleDelete = async (id) => {
    if (!window.confirm('Delete this product?')) return;
    await fetch(`${API_BASE}/api/products/${id}`, { method: 'DELETE' });
    fetchProducts();
  };

  return (
    <div style={{ maxWidth: 800, margin: '40px auto', fontFamily: 'sans-serif', padding: '0 20px' }}>
      <h1>MNC Product Catalog</h1>
      <p style={{ color: '#666', fontSize: 13 }}>
        Environment: <strong>{process.env.REACT_APP_ENV || 'local'}</strong> |
        API: <code style={{ fontSize: 12 }}>{API_BASE}</code>
      </p>

      {/* Add Product Form */}
      <div style={{ background: '#f5f5f5', padding: 20, borderRadius: 8, marginBottom: 24 }}>
        <h2 style={{ marginTop: 0 }}>Add Product</h2>
        <form onSubmit={handleCreate} style={{ display: 'grid', gap: 10 }}>
          <input placeholder="Name" required value={newProduct.name}
            onChange={e => setNewProduct({...newProduct, name: e.target.value})}
            style={{ padding: 8, borderRadius: 4, border: '1px solid #ddd' }} />
          <input placeholder="Description" value={newProduct.description}
            onChange={e => setNewProduct({...newProduct, description: e.target.value})}
            style={{ padding: 8, borderRadius: 4, border: '1px solid #ddd' }} />
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10 }}>
            <input placeholder="Price (e.g. 99.99)" type="number" step="0.01" required value={newProduct.price}
              onChange={e => setNewProduct({...newProduct, price: e.target.value})}
              style={{ padding: 8, borderRadius: 4, border: '1px solid #ddd' }} />
            <input placeholder="Stock quantity" type="number" required value={newProduct.stockQuantity}
              onChange={e => setNewProduct({...newProduct, stockQuantity: e.target.value})}
              style={{ padding: 8, borderRadius: 4, border: '1px solid #ddd' }} />
          </div>
          <button type="submit" style={{ padding: '10px 20px', background: '#0066cc', color: '#fff', border: 'none', borderRadius: 4, cursor: 'pointer' }}>
            Add Product
          </button>
        </form>
      </div>

      {/* Product List */}
      {error   && <div style={{ color: 'red', marginBottom: 16 }}>Error: {error}</div>}
      {loading && <p>Loading...</p>}
      {!loading && !error && (
        <table style={{ width: '100%', borderCollapse: 'collapse' }}>
          <thead>
            <tr style={{ background: '#eee' }}>
              {['ID', 'Name', 'Description', 'Price', 'Stock', 'Actions'].map(h => (
                <th key={h} style={{ padding: '10px 12px', textAlign: 'left', fontSize: 13 }}>{h}</th>
              ))}
            </tr>
          </thead>
          <tbody>
            {products.length === 0 && (
              <tr><td colSpan={6} style={{ padding: 20, textAlign: 'center', color: '#999' }}>No products yet</td></tr>
            )}
            {products.map(p => (
              <tr key={p.id} style={{ borderBottom: '1px solid #eee' }}>
                <td style={{ padding: '8px 12px', fontSize: 13 }}>{p.id}</td>
                <td style={{ padding: '8px 12px', fontWeight: 500 }}>{p.name}</td>
                <td style={{ padding: '8px 12px', fontSize: 13, color: '#666' }}>{p.description || '—'}</td>
                <td style={{ padding: '8px 12px' }}>₹{p.price}</td>
                <td style={{ padding: '8px 12px' }}>{p.stockQuantity}</td>
                <td style={{ padding: '8px 12px' }}>
                  <button onClick={() => handleDelete(p.id)}
                    style={{ padding: '4px 10px', background: '#cc0000', color: '#fff', border: 'none', borderRadius: 4, cursor: 'pointer', fontSize: 12 }}>
                    Delete
                  </button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </div>
  );
}

export default App;
