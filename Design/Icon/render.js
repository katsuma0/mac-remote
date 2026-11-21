// usage: node render.js in.svg out.png size
const { chromium } = require('playwright');
const fs = require('fs');
(async () => {
  const [,, input, output, sizeArg] = process.argv;
  const size = parseInt(sizeArg || '1024', 10);
  const svg = fs.readFileSync(input, 'utf8');
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: size, height: size }, deviceScaleFactor: 1 });
  await page.setContent(`<html><body style="margin:0;background:transparent">
    <div style="width:${size}px;height:${size}px">${svg.replace('<svg ', `<svg width="${size}" height="${size}" `)}</div></body></html>`);
  await page.screenshot({ path: output, omitBackground: true, clip: { x: 0, y: 0, width: size, height: size } });
  await browser.close();
})();
