// fixed-server.js
const express = require('express');
const multer = require('multer');
const mammoth = require('mammoth');
const path = require('path');

const app = express();
const PORT = 3000;

const storage = multer.memoryStorage();
const upload = multer({
  storage: storage,
  limits: { fileSize: 10 * 1024 * 1024 },
  fileFilter: (req, file, cb) => {
    if (path.extname(file.originalname).toLowerCase() === '.docx') {
      cb(null, true);
    } else {
      cb(new Error('只支持 .docx 文件'));
    }
  }
});

// 高亮转换函数
function processHighlights(html) {
  // 将Word的高亮样式转换为HTML高亮
  return html.replace(/<span[^>]*background:yellow[^>]*>(.*?)<\/span>/gi, '<mark>$1</mark>')
             .replace(/<span[^>]*background-color:yellow[^>]*>(.*?)<\/span>/gi, '<mark>$1</mark>')
             .replace(/<span[^>]*background-color:#?ffff00[^>]*>(.*?)<\/span>/gi, '<mark>$1</mark>')
             .replace(/<span[^>]*background:#?ffff00[^>]*>(.*?)<\/span>/gi, '<mark>$1</mark>');
}

// 转换接口
app.post('/convert', upload.single('file'), async (req, res) => {
  try {
    if (!req.file) {
      return res.json({ error: '请上传文件' });
    }

    console.log('正在转换文件:', req.file.originalname);
    
    // 使用 mammoth 转换，添加编码处理
    const result = await mammoth.convertToHtml({ 
      buffer: req.file.buffer 
    });
    
    console.log('原始内容长度:', result.value.length);
    
    // 处理高亮
    const htmlWithHighlights = processHighlights(result.value);
    
    // 构建完整的HTML，确保UTF-8编码
    const fullHtml = `<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <meta http-equiv="Content-Type" content="text/html; charset=UTF-8">
  <style>
    /* 强制UTF-8编码 */
    * { 
      font-family: Arial, "Microsoft YaHei", "微软雅黑", sans-serif;
    }
    
    /* 表格样式 */
    table {
      border-collapse: collapse;
      width: 100%;
      border: 1px solid #000;
      margin: 10px 0;
    }
    th, td {
      border: 1px solid #000;
      padding: 8px;
    }
    th {
      background-color: #f2f2f2;
    }
    
    /* 高亮样式 */
    mark {
      background-color: yellow;
      padding: 2px 4px;
    }
    
    /* 通用样式 */
    body {
      font-family: Arial, "Microsoft YaHei", "微软雅黑", sans-serif;
      line-height: 1.6;
      margin: 20px;
    }
  </style>
</head>
<body>
${htmlWithHighlights}
</body>
</html>`;
    
    // 设置响应头确保编码正确
    res.setHeader('Content-Type', 'application/json; charset=utf-8');
    
    res.json({
      success: true,
      html: fullHtml,
      filename: req.file.originalname
    });
    
  } catch (error) {
    console.error('转换错误:', error);
    res.setHeader('Content-Type', 'application/json; charset=utf-8');
    res.json({
      success: false,
      error: error.message
    });
  }
});

// 直接下载HTML文件的接口
app.post('/convert-download', upload.single('file'), async (req, res) => {
  try {
    if (!req.file) {
      return res.status(400).send('请上传文件');
    }

    const result = await mammoth.convertToHtml({ 
      buffer: req.file.buffer 
    });
    
    const htmlWithHighlights = processHighlights(result.value);
    
    const fullHtml = `<!DOCTYPE html>
<html>
<head>
  <meta charset="UTF-8">
  <meta http-equiv="Content-Type" content="text/html; charset=UTF-8">
  <style>
    * { font-family: Arial, "Microsoft YaHei", "微软雅黑", sans-serif; }
    table { border-collapse: collapse; width: 100%; border: 1px solid #000; margin: 10px 0; }
    th, td { border: 1px solid #000; padding: 8px; }
    th { background-color: #f2f2f2; }
    mark { background-color: yellow; padding: 2px 4px; }
    body { font-family: Arial, "Microsoft YaHei", "微软雅黑", sans-serif; line-height: 1.6; margin: 20px; }
  </style>
</head>
<body>${htmlWithHighlights}</body>
</html>`;
    
    res.setHeader('Content-Type', 'text/html; charset=utf-8');
    res.setHeader('Content-Disposition', 'attachment; filename="converted.html"');
    res.send(fullHtml);
    
  } catch (error) {
    res.status(500).send('转换失败: ' + error.message);
  }
});

app.listen(PORT, () => {
  console.log(`服务器运行在 http://localhost:${PORT}`);
  console.log('POST /convert - 返回JSON格式的HTML');
  console.log('POST /convert-download - 直接下载HTML文件');
});