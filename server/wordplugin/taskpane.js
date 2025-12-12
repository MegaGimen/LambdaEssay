Office.onReady((info) => {
    if (info.host === Office.HostType.Word) {
        document.getElementById("insert-text").onclick = insertText;
        document.getElementById("save-doc").onclick = saveDocument;
        document.getElementById("check-saved").onclick = checkSavedStatus;
        document.getElementById("register-monitor").onclick = registerMonitor;
        log("Word Plugin Ready.");
    }
});

async function insertText() {
    await Word.run(async (context) => {
        const body = context.document.body;
        body.insertParagraph("Hello from Word Plugin!", "End");
        await context.sync();
        log("Text inserted.");
    }).catch(errorHandler);
}

async function saveDocument() {
    await Word.run(async (context) => {
        // Save the document
        context.document.save();
        await context.sync();
        log("Save command executed.");
    }).catch(errorHandler);
}

async function checkSavedStatus() {
    await Word.run(async (context) => {
        const doc = context.document;
        doc.load("saved");
        await context.sync();
        
        if (doc.saved) {
            log("Document is saved.");
        } else {
            log("Document has unsaved changes.");
        }
    }).catch(errorHandler);
}

function registerMonitor() {
    // There isn't a direct "OnSave" event, but we can monitor selection changes
    // and check the saved status frequently.
    Office.context.document.addHandlerAsync(
        Office.EventType.DocumentSelectionChanged,
        onSelectionChanged,
        (result) => {
            if (result.status === Office.AsyncResultStatus.Succeeded) {
                log("Monitoring selection changes (Mock Monitor).");
            } else {
                log("Failed to register monitor: " + result.error.message);
            }
        }
    );
}

async function onSelectionChanged(eventArgs) {
    // When selection changes, check if document is saved
    await Word.run(async (context) => {
        const doc = context.document;
        doc.load("saved");
        await context.sync();
        // Log only if it changes or just a debug message
        // console.log("Current saved status: " + doc.saved);
    }).catch((e) => console.error(e));
}

function log(message) {
    const consoleOutput = document.getElementById("console-output");
    const time = new Date().toLocaleTimeString();
    consoleOutput.textContent += `[${time}] ${message}\n`;
}

function errorHandler(error) {
    log("Error: " + error.message);
    console.error(error);
}
