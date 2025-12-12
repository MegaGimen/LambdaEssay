const express = require('express');
const http = require('http');
const WebSocket = require('ws');
const cors = require('cors');
const bodyParser = require('body-parser');

const app = express();
const port = 3001;

// Middleware
app.use(cors());
app.use(bodyParser.json({ limit: '50mb' })); // Allow large payloads for documents
app.use(bodyParser.urlencoded({ extended: true, limit: '50mb' }));

const server = http.createServer(app);
const wss = new WebSocket.Server({ server });

let activeSocket = null;

wss.on('connection', (ws) => {
    console.log('Client connected');
    activeSocket = ws;

    ws.on('close', () => {
        console.log('Client disconnected');
        if (activeSocket === ws) {
            activeSocket = null;
        }
    });

    ws.on('message', (message) => {
        console.log('Received:', message);
    });
});

// API Routes

// Health check
app.get('/api/health', (req, res) => {
    res.json({ status: 'ok', connected: !!activeSocket });
});

// Trigger Save
app.post('/api/save', (req, res) => {
    if (!activeSocket) {
        return res.status(503).json({ error: 'Plugin not connected' });
    }
    
    activeSocket.send(JSON.stringify({ action: 'save' }));
    res.json({ message: 'Save command sent' });
});

// Replace Document
app.post('/api/document', (req, res) => {
    if (!activeSocket) {
        return res.status(503).json({ error: 'Plugin not connected' });
    }

    const { content, type } = req.body;

    if (!content) {
        return res.status(400).json({ error: 'Content is required' });
    }

    // Default type to 'text' if not provided
    const contentType = type || 'text'; 

    activeSocket.send(JSON.stringify({ 
        action: 'replace', 
        payload: { content, type: contentType } 
    }));

    res.json({ message: 'Replace command sent' });
});

server.listen(port, () => {
    console.log(`API Server listening at http://localhost:${port}`);
    console.log(`WebSocket Server listening at ws://localhost:${port}`);
});
