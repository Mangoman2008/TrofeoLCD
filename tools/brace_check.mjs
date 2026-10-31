import fs from 'node:fs'
const p=process.argv[2]
const src=fs.readFileSync(p,'utf8')
let i=0, mode=null, out='', line=1
const marks=[]
while(i<src.length){
  const c=src[i], n=src[i+1]
  if(c==='\n') line++
  if(mode===null){
    if(c==='/'&&n==='/'){ mode='line'; i+=2; continue }
    if(c==='/'&&n==='*'){ mode='block'; i+=2; continue }
    if(c==="'"||c==='"'||c==='`'){ mode=c; i++; continue }
    out+=c
  } else if(mode==='line'){ if(c==='\n') mode=null }
  else if(mode==='block'){ if(c==='*'&&n==='/'){ mode=null; i+=2; continue } }
  else { if(c==='\\'){ i+=2; continue } if(c===mode) mode=null }
  i++
}
const o=(out.match(/\{/g)||[]).length, cl=(out.match(/\}/g)||[]).length
const po=(out.match(/\(/g)||[]).length, pc=(out.match(/\)/g)||[]).length
console.log(`  { = ${o}   } = ${cl}   差 = ${o-cl}`)
console.log(`  ( = ${po}   ) = ${pc}   差 = ${po-pc}`)
console.log(`  残留 mode = ${mode}`)
