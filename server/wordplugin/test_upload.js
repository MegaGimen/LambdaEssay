const axios = require('axios');
const FormData = require('form-data');
const fs = require('fs');
const path = require('path');

async function uploadDocument() {
    const filePath = process.argv[2];
    const fontName = process.argv[3];

    if (!filePath) {
        console.error('Please provide a file path.');
        console.error('Usage: node test_upload.js <path-to-docx> [font-name]');
        process.exit(1);
    }

    if (!fs.existsSync(filePath)) {
        console.error(`File not found: ${filePath}`);
        process.exit(1);
    }

    const form = new FormData();
    form.append('file', fs.createReadStream(filePath));
    
    // Add options if font name is provided
    if (fontName) {
        const options = JSON.stringify({ fontName: fontName });
        form.append('options', options);
        console.log(`Requesting forced font: ${fontName}`);
    }

    try {
        const response = await axios.post('http://localhost:3001/api/document', form, {
            headers: {
                ...form.getHeaders()
            }
        });
        console.log('Success:', response.data);
    } catch (error) {
        if (error.response) {
            console.error('Error:', error.response.status, error.response.data);
        } else {
            console.error('Error:', error.message);
        }
    }
}

uploadDocument();
