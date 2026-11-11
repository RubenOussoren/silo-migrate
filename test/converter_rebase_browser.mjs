// Invented push approvals only; all requests intercepted. No credentials, GitHub or models.
// Run from repository root with PLAYWRIGHT_CORE and CHROMIUM pointing at existing installations.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
const { chromium } = await import(pathToFileURL(resolve(process.env.PLAYWRIGHT_CORE)));
const browser = await chromium.launch({ executablePath: process.env.CHROMIUM });
const folder = resolve('integrations/term-llm/widgets/project');
try {
 for (const rewrite of [false, true]) {
  const page = await browser.newPage({ viewport: { width: 1000, height: 850 } });
  const errors = [], posts = [];
  let proposed = true;
  const data = { digest:'d'.repeat(64), repository:'invented/converters', branch:'migration/example-forum/converter', base:'main', head:'a'.repeat(40),
   title:'Shared upstream feature', body:'Invented change', findings:[], commits:[{sha:'a'.repeat(40),subject:'Checkpoint profile edits'}], files:[], files_total:0,
   ...(rewrite ? {rewrite:{mode:'force-with-lease',expected_remote_head:'b'.repeat(40),main_head:'c'.repeat(40),before_head:'b'.repeat(40)}} : {}) };
  page.on('pageerror', error=>errors.push(error.message));
  await page.route('**/*',async route=>{
   const r=route.request(),u=new URL(r.url());assert.equal(u.origin,'http://rebase.test');
   if (u.pathname==='/') return route.fulfill({contentType:'text/html',body:'<body><section id="content"></section><div id="toast"></div></body>'});
   if (u.pathname==='/api/runs/push' && r.method()==='GET') return route.fulfill({contentType:'application/json',body:JSON.stringify({...data,status:proposed?'proposed':'pushed',pull_request:proposed?null:{number:7,url:'https://example.invalid/pr/7'}})});
   if (u.pathname==='/api/runs/push') {posts.push(r.postDataJSON());proposed=false;return route.fulfill({contentType:'application/json',body:'{"status":"pushed","pull_request":{"number":7}}'});}
   return route.fulfill({contentType:'text/javascript',body:readFileSync(resolve(folder,u.pathname.slice(1)))});
  });
  await page.goto('http://rebase.test/');
  await page.evaluate(async()=>{
   window.questions=[];window.approve=false;window.confirm=q=>{questions.push(q);return approve;};
   const{runsView}=await import('/runs.js');
   window.view=runsView({project:'example-forum',selected:{kind:'push',id:'d'.repeat(64)},mount:nodes=>document.querySelector('#content').replaceChildren(...nodes.filter(Boolean)),refresh:()=>view.show(),close:()=>{}});
   await view.show();
  });
  const button=page.getByRole('button',{name:rewrite?'Push rebased branch…':'Push and open draft PR',exact:true});await button.waitFor();
  if(rewrite)assert.match(await page.locator('#content').innerText(),/replaces this migration branch’s history/);
  await button.click();assert.equal(posts.length,0,'cancelled confirmation never posts');
  await page.evaluate(()=>approve=true);await button.click();
  await page.getByText('This push is pushed.',{exact:true}).waitFor();
  assert.deepEqual(posts,[{workspace:'example-forum',digest:'d'.repeat(64),...(rewrite?{rewrite:true}:{})}]);
  const question=(await page.evaluate(()=>questions)).at(-1);
  if(rewrite){assert(question.includes('b'.repeat(40)));assert(question.includes('a'.repeat(40)));assert.match(question,/Main is never pushed/);assert.match(question,/If the branch moved, nothing is pushed/);}
  else assert(!question.includes('Replace the history'));
  assert.deepEqual(errors,[]);await page.close();
 }
 console.log('REBASE_PUSH_APPROVAL_OK: normal and rewrite approvals, cancellation, exact digest/head/lease and boolean acknowledgement');
} finally {await browser.close();}
