const express = require('express');
const http = require('http');
const WebSocket = require('ws');
const cors = require('cors');
const bodyParser = require('body-parser');
const multer = require('multer');

const app = express();
const port = 3001;

// Configure Multer for memory storage
const upload = multer({ 
    storage: multer.memoryStorage(),
    limits: { fileSize: 50 * 1024 * 1024 } // Limit to 50MB
});

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
app.post('/api/document', upload.single('file'), (req, res) => {
    if (!activeSocket) {
        return res.status(503).json({ error: 'Plugin not connected' });
    }

    let content, type;

    // Check if file was uploaded
    if (req.file) {
        console.log(`Received file: ${req.file.originalname}, size: ${req.file.size}`);
        content = req.file.buffer.toString('base64');
        type = 'base64';
    } else {
        // Fallback to JSON body
        content = req.body.content;
        type = req.body.type || 'text';
    }

    // Parse options
    let options = {};
    if (req.body.options) {
        try {
            options = typeof req.body.options === 'string' ? JSON.parse(req.body.options) : req.body.options;
        } catch (e) {
            console.error("Failed to parse options:", e);
        }
    }

    if (!content) {
        return res.status(400).json({ error: 'Content is required (either as file or JSON body)' });
    }

    activeSocket.send(JSON.stringify({ 
        action: 'replace', 
        payload: { content, type, options } 
    }));

    res.json({ message: 'Replace command sent' });
});

server.listen(port, () => {
    console.log(`API Server listening at http://localhost:${port}`);
    console.log(`WebSocket Server listening at ws://localhost:${port}`);
});
