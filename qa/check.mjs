// QA en la nube: responsive (0 desbordamiento) + 0 errores JS + piezas clave, para index.html y app.html.
import {chromium} from 'playwright';
import {spawn} from 'child_process';
const srv=spawn('python3',['-m','http.server','8080'],{stdio:'ignore'});
await new Promise(r=>setTimeout(r,1500));
const base='http://127.0.0.1:8080';
let fail=0;
const b=await chromium.launch();
try{
  for(const w of [360,390,768,1280]){
    const p=await b.newPage({viewport:{width:w,height:900}});
    const errs=[];p.on('console',m=>{if(m.type()==='error')errs.push(m.text());});p.on('pageerror',e=>errs.push('PE '+e.message));
    await p.goto(base+'/index.html',{waitUntil:'networkidle'});await p.waitForTimeout(500);
    const m=await p.evaluate(()=>({iw:innerWidth,sw:document.documentElement.scrollWidth,club:!!document.getElementById('club'),logo:!!document.querySelector('.nav-logo')}));
    const re=errs.filter(e=>!/favicon/i.test(e)), ov=m.sw>m.iw+1;
    console.log(`index W${w}: overflow=${ov?'FAIL':'ok'} kuxtalClub=${m.club} logo=${m.logo} jsErrs=${re.length}`);
    if(ov){fail++;console.log('  ↳ desbordamiento',m.sw,'>',m.iw);}
    if(!m.club){fail++;console.log('  ↳ falta sección Kuxtal Club');}
    if(re.length){fail++;console.log('  ↳ JS:',re.slice(0,3).join(' | '));}
    await p.close();
  }
  const q=await b.newPage({viewport:{width:390,height:800}});
  const e2=[];q.on('console',m=>{if(m.type()==='error')e2.push(m.text());});q.on('pageerror',e=>e2.push('PE '+e.message));
  await q.goto(base+'/app.html',{waitUntil:'load'});await q.waitForTimeout(2500);
  const gate=await q.evaluate(()=>getComputedStyle(document.getElementById('gate')).display);
  const re2=e2.filter(e=>!/favicon/i.test(e));
  console.log(`app.html (CRM): login(#gate)=${gate} jsErrs=${re2.length}`);
  if(gate!=='flex'){fail++;console.log('  ↳ el login del CRM no aparece');}
  if(re2.length){fail++;console.log('  ↳ CRM JS:',re2.slice(0,3).join(' | '));}
  await q.close();
}finally{await b.close();srv.kill();}
console.log(fail?`\n❌ QA FALLÓ (${fail} problema/s)`:'\n✅ QA OK — responsive, sin errores, piezas presentes');
process.exit(fail?1:0);
