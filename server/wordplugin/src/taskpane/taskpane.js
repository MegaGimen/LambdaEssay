/*
 * Copyright (c) Microsoft Corporation. All rights reserved. Licensed under the MIT license.
 * See LICENSE in the project root for license information.
 */

/* global document, Office, Word, setInterval, clearInterval */

Office.onReady((info) => {
  if (info.host === Office.HostType.Word) {
    document.getElementById("sideload-msg").style.display = "none";
    document.getElementById("app-body").style.display = "flex";
    
    document.getElementById("write-text").onclick = writeText;
    document.getElementById("save-document").onclick = saveDocument;
    document.getElementById("monitor-save").onclick = monitorSave;
  }
});

function log(message) {
    const logDiv = document.getElementById("status-log");
    const p = document.createElement("p");
    p.innerText = `${new Date().toLocaleTimeString()} - ${message}`;
    p.style.margin = "2px 0";
    p.style.fontSize = "12px";
    logDiv.insertBefore(p, logDiv.firstChild);
}

function errorHandler(error) {
    console.error(error);
    log("Error: " + error.message);
    if (error instanceof OfficeExtension.Error) {
        log("Debug info: " + JSON.stringify(error.debugInfo));
    }
}

export async function writeText() {
  return Word.run(async (context) => {
    const paragraph = context.document.body.insertParagraph("Hello from Word Plugin API!", Word.InsertLocation.end);
    paragraph.font.color = "blue";
    await context.sync();
    log("Text written to document.");
  }).catch(errorHandler);
}

export async function saveDocument() {
  return Word.run(async (context) => {
    context.document.save();
    await context.sync();
    log("Document saved via API.");
  }).catch(errorHandler);
}

let monitorInterval;
let lastSavedState = null;

async function checkSaveStatus() {
     await Word.run(async (context) => {
        const doc = context.document;
        doc.load("saved");
        await context.sync();
        
        if (lastSavedState !== doc.saved) {
            lastSavedState = doc.saved;
            log(`Document Saved State: ${doc.saved ? "Saved" : "Unsaved (Dirty)"}`);
        }
    }).catch(errorHandler);
}

export async function monitorSave() {
    const btnLabel = document.getElementById("monitor-save").querySelector(".ms-Button-label");
    
    if (monitorInterval) {
        clearInterval(monitorInterval);
        monitorInterval = null;
        log("Stopped monitoring save status.");
        btnLabel.innerText = "Start Monitoring Save";
        return;
    }

    log("Started monitoring save status...");
    btnLabel.innerText = "Stop Monitoring Save";
    
    // Reset state so we get an initial log
    lastSavedState = null;

    // Check immediately
    checkSaveStatus();

    monitorInterval = setInterval(() => {
        checkSaveStatus();
    }, 2000);
}
