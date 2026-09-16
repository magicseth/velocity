import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdtempSync,writeFileSync,mkdirSync,symlinkSync,rmSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
const fixture=mkdtempSync(join(tmpdir(),'prefrontal-inspect-'));
const script=resolve('resources/directory-inspector.py');
const run=(path:string)=>{const raw=execFileSync('python3',[script,path],{encoding:'utf8',timeout:20000,maxBuffer:100000});assert.ok(Buffer.byteLength(raw)<=32000);return JSON.parse(raw);};
const git=(...args:string[])=>execFileSync('git',['-C',fixture,...args],{stdio:'pipe',env:{...process.env,GIT_CONFIG_GLOBAL:'/dev/null',GIT_CONFIG_NOSYSTEM:'1'}});
try{
 git('init');git('config','user.email','fixture@example.test');git('config','user.name','Fixture');
 writeFileSync(join(fixture,'README.md'),'# Widget\nManages widgets for local users.\n');
 writeFileSync(join(fixture,'app.ts'),'export const value = 1;\n');
 git('add','README.md','app.ts');git('commit','-m','Add widget app');
 writeFileSync(join(fixture,'app.ts'),'export const value = 2;\nconst api_key = "must-not-appear";\n');
 writeFileSync(join(fixture,'.env.local'),'UNIQUE_PRIVATE_ENV_VALUE');
 writeFileSync(join(fixture,'credentials.json'),'UNIQUE_PRIVATE_CREDENTIAL_VALUE');
 writeFileSync(join(fixture,'package.json'),'{"name":"widget","description":"A test widget"}');
 const outside=join(fixture,'private-secrets');mkdirSync(outside);writeFileSync(join(outside,'hidden.ts'),'UNIQUE_SYMLINK_SECRET');
 symlinkSync(join(outside,'hidden.ts'),join(fixture,'escape.ts'));
 symlinkSync(outside,join(fixture,'linked')); // nested escapes are excluded as well
 const first=run(fixture), serialized=JSON.stringify(first);
 assert.equal(first.version,1);assert.match(first.fingerprint,/^[a-f0-9]{64}$/);
 assert.equal(first.fingerprint,run(fixture).fingerprint,'Stable fingerprint ignores observation time');
 const repo=first.items.find((i:any)=>i.id==='git');assert.ok(repo);assert.equal(repo.recentCommits[0].subject,'Add widget app');
 assert.ok(repo.status.some((i:any)=>i.path==='app.ts'&&i.status.includes('M')));
 assert.ok(repo.diffStats.unstaged.some((i:any)=>i.path==='app.ts'&&i.added==='2'));
 assert.ok(first.items.some((i:any)=>i.id==='document:README.md'&&i.excerpt.includes('widgets')));
 assert.ok(first.items.some((i:any)=>i.id==='changed:app.ts'&&i.excerpt.includes('value = 2')));
 for(const forbidden of ['UNIQUE_PRIVATE_ENV_VALUE','UNIQUE_PRIVATE_CREDENTIAL_VALUE','UNIQUE_SYMLINK_SECRET','must-not-appear'])assert.ok(!serialized.includes(forbidden),forbidden+' must be excluded');
 assert.ok(!first.items.some((i:any)=>i.id==='changed:escape.ts'));
 writeFileSync(join(fixture,'app.ts'),'export const value = 3;\n');assert.notEqual(first.fingerprint,run(fixture).fingerprint);
 const plain=join(fixture,'plain');mkdirSync(plain);writeFileSync(join(plain,'README.md'),'Plain child directory');
 const child=run(plain);const childGit=child.items.find((i:any)=>i.id==='git');assert.ok(!childGit.status.some((i:any)=>i.path==='app.ts'),'Subdirectory does not inherit parent changes');
 const nonGit=mkdtempSync(join(tmpdir(),'prefrontal-plain-'));
 try{writeFileSync(join(nonGit,'README.md'),'Independent plain directory');const evidence=run(nonGit);assert.ok(!evidence.items.some((i:any)=>i.id==='git'));assert.ok(evidence.items.some((i:any)=>i.id==='document:README.md'));}finally{rmSync(nonGit,{recursive:true,force:true});}
 const missing=run(join(fixture,'missing'));assert.ok(missing.errors.length);assert.equal(missing.items.length,1);
 const linked=run(join(fixture,'linked'));assert.match(linked.errors[0],/symbolic link/);
 writeFileSync(join(fixture,'README.md'),'x'.repeat(100000));assert.equal(run(fixture).items.find((i:any)=>i.id==='document:README.md').truncated,true);
 console.log('PASS Velocity directory inspector: real git evidence, changed files, stable fingerprints, size limits, secret and symlink exclusion, missing directories and subtree scope');
}finally{rmSync(fixture,{recursive:true,force:true});}
