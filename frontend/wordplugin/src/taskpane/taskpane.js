/*
 * Copyright (c) Microsoft Corporation. All rights reserved. Licensed under the MIT license.
 * See LICENSE in the project root for license information.
 */

/* global document, Office, Word, setInterval, clearInterval, WebSocket, console */

let ws;
const WS_URL = "ws://localhost:8080/ws";

Office.onReady((info) => {
  if (info.host === Office.HostType.Word) {
    log("Office Add-in ready. Monitoring connection status.");

    // Connect to WebSocket Server
    connectWebSocket();

    // Start monitoring automatically
    startAutoSaveMonitor();
  }
});


function connectWebSocket() {
    log(`Connecting to ${WS_URL}...`);
    updateConnectionStatus(false, "Connecting...");
    ws = new WebSocket(WS_URL);

    ws.onopen = () => {
        log("Connected to API Server");
        updateConnectionStatus(true);
    };

    ws.onclose = () => {
        log("Disconnected from API Server");
        updateConnectionStatus(false);
        // Try to reconnect after 5 seconds
        setTimeout(connectWebSocket, 5000);
    };

    ws.onerror = (error) => {
        console.error("WebSocket error:", error);
        log("Connection Error");
        updateConnectionStatus(false, "Error");
    };

    ws.onmessage = async (event) => {
        try {
            const data = JSON.parse(event.data);
            log(`Received command: ${data.action}`);
            
            if (data.action === 'save') {
                await saveDocument(data.id);
            } else if (data.action === 'replace') {
                await replaceDocument(data.payload, data.id);
                await saveDocument(data.id);
            }
        } catch (e) {
            log("Error processing message: " + e.message);
        }
    };
}

function updateConnectionStatus(connected, statusText) {
    const indicator = document.getElementById('status-indicator');
    const textSpan = document.getElementById('status-text');
    
    if (indicator && textSpan) {
        if (connected) {
            indicator.className = 'status-indicator connected';
            textSpan.textContent = 'Connected';
        } else {
            indicator.className = 'status-indicator disconnected';
            textSpan.textContent = statusText || 'Disconnected';
        }
    } else {
        console.error("DOM elements not found in updateConnectionStatus");
    }
    console.log(connected ? "API: Connected" : "API: Disconnected");
}

function log(message) {
    console.log(`${new Date().toLocaleTimeString()} - ${message}`);
}

function errorHandler(error) {
    console.error(error);
    log("Error: " + error.message);
    if (error instanceof OfficeExtension.Error) {
        log("Debug info: " + JSON.stringify(error.debugInfo));
    }
}

async function saveDocument(id) {
  return Word.run(async (context) => {
    context.document.save();
    await context.sync();
    log("Document saved via API.");
    if (ws && ws.readyState === WebSocket.OPEN && id) {
       ws.send(JSON.stringify({
          type: 'response',
          id: id,
          status: 'success'
       }));
    }
  }).catch(errorHandler);
}

async function replaceDocument(payload, id) {
  return Word.run(async (context) => {
    const { content, type, options } = payload;
    
    // Check path if required
    if (options && options.checkPath) {
       const currentUrl = Office.context.document.url;
       // Normalize paths for comparison
       // Remove file:/// and convert forward slashes to backslashes or vice versa
       let normCurrent = currentUrl ? currentUrl.replace(/^file:\/\/\//, '').replace(/\//g, '\\') : '';
       try { normCurrent = decodeURIComponent(normCurrent); } catch(e) {}
       
       let normTarget = options.checkPath.replace(/\//g, '\\');
       
       // Handle drive letter capitalization differences
       if (normCurrent.toLowerCase() !== normTarget.toLowerCase()) {
          console.log(`Path mismatch. Current: ${normCurrent}, Target: ${normTarget}`);
          log(`Path mismatch. Current: ${normCurrent}, Target: ${normTarget}`);
          if (ws && ws.readyState === WebSocket.OPEN && id) {
             ws.send(JSON.stringify({
                type: 'response',
                id: id,
                status: 'error',
                message: `Document path mismatch. Expected ${normTarget}, got ${normCurrent}`
             }));
          }
          return;
       }
    }

    const body = context.document.body;
    
    if (type === 'html') {
        // use Replace to overwrite existing content
        body.insertHtml(content, Word.InsertLocation.replace);
    } else if (type === 'base64') {
        // use Replace to overwrite existing content, which handles styles better than clear() + insert()
        body.insertFileFromBase64(content, Word.InsertLocation.replace);
    } else {
        // Default text
        // insertParagraph does not support 'Replace', so we clear first
        body.clear();
        body.insertParagraph(content, Word.InsertLocation.start);
    }

    // Handle force options (Direct Formatting Override)
    if (options) {
        if (options.fontName) {
            body.font.name = options.fontName;
            log(`Forced font name: ${options.fontName}`);
        }
        if (options.fontSize) {
            body.font.size = options.fontSize;
            log(`Forced font size: ${options.fontSize}`);
        }
        // Add more style overrides as needed
    }

    await context.sync();
    log("Document content replaced via API.");
    
    if (ws && ws.readyState === WebSocket.OPEN && id) {
       ws.send(JSON.stringify({
          type: 'response',
          id: id,
          status: 'success'
       }));
    }
  }).catch((error) => {
      errorHandler(error);
      if (ws && ws.readyState === WebSocket.OPEN && id) {
         ws.send(JSON.stringify({
            type: 'response',
            id: id,
            status: 'error',
            message: error.message
         }));
      }
  });
}

let monitorInterval;
let lastSavedState = null;

function startAutoSaveMonitor() {
    if (monitorInterval) clearInterval(monitorInterval);
    log("Auto-save monitor started.");
    monitorInterval = setInterval(() => {
        checkSaveStatus();
    }, 1000);
}

async function sendSaveEvent() {
    if (ws && ws.readyState === WebSocket.OPEN) {
       const currentUrl = Office.context.document.url;
       let normUrl = currentUrl ? currentUrl.replace(/^file:\/\/\//, '').replace(/\//g, '\\') : '';
       try { normUrl = decodeURIComponent(normUrl); } catch(e) {}
       
       ws.send(JSON.stringify({
          type: 'event',
          event: 'saved',
          path: normUrl
       }));
       log("Sent save event to server");
    }
}

async function checkSaveStatus() {
     await Word.run(async (context) => {
        const doc = context.document;
        doc.load("saved");
        await context.sync();
        
        if (lastSavedState !== doc.saved) {
            // Check for transition from Dirty (false) to Saved (true)
            // Ignore initial state (null)
            if (lastSavedState === false && doc.saved === true) {
                log("Detected Document Save! Triggering Sync...");
                await sendSaveEvent();
            }
            
            lastSavedState = doc.saved;
        }
    }).catch((e) => {
        // Suppress minor errors
    });
}
