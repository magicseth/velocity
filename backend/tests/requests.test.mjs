import { test } from 'node:test';
import assert from 'node:assert/strict';
import { openRequest, validateOpenProposal } from '../lib/requests.ts';
const id = '19d10d29-e2e6-47d6-bd89-59ed954bf3a1';
const input = {text:'Open the Waveshare terminal',resources:[{id,app:'Terminal',title:'Waveshare',kind:'Tab'}]};
test('open proposals must reference real unique targets and contain no executable payload', () => {
 assert.deepEqual(validateOpenProposal(input,{message:'Found it',candidates:[id]}).candidates,[id]);
 assert.throws(() => validateOpenProposal(input,{message:'Oops',candidates:['49d10d29-e2e6-47d6-bd89-59ed954bf3a1']}));
 assert.throws(() => validateOpenProposal(input,{message:'Oops',candidates:[id,id]}));
 assert.throws(() => validateOpenProposal(input,{message:'Oops',candidates:[id],script:'do something'}));
 assert.throws(() => validateOpenProposal({...input,resources:[...input.resources,...input.resources]}, {message:'Oops',candidates:[]}));
});
test('request text is bounded and unsupported requests can return no matches', () => {
 assert.throws(() => openRequest.parse({...input,text:''}));
 assert.throws(() => openRequest.parse({...input,text:'x'.repeat(2001)}));
 assert.deepEqual(validateOpenProposal(input,{message:'Not supported',candidates:[]}).candidates,[]);
});

import { textRequest, validateTextProposal } from '../lib/requests.ts';
const sharing = {adapters:[{id:'messages',name:'Messages',capability:'shareLink'}],text:'Send Kyle the video',resources:[{...input.resources[0],canShare:true,playing:true}]};
test('sharing proposals require a recipient and shareable source; cannot contain arbitrary actions or message text', () => {
 const proposal={intent:'shareLink',message:'Choose recipient',candidates:[id],recipient:'Kyle',adapterID:'messages'};
 assert.equal(validateTextProposal(textRequest.parse(sharing),proposal).intent,'shareLink');
 assert.throws(()=>validateTextProposal(sharing,{...proposal,recipient:null}));
 assert.throws(()=>validateTextProposal({...sharing,resources:[{...sharing.resources[0],canShare:false}]},proposal));
 assert.throws(()=>validateTextProposal(sharing,{...proposal,body:'unapproved text'}));
 assert.throws(()=>validateTextProposal(sharing,{...proposal,intent:'shell'}));
 assert.throws(()=>validateTextProposal(sharing,{...proposal,intent:'unsupported'}));
});
test('unknown delivery adapters cannot be dispatched or silently substituted', () => {
 const proposal={intent:'shareLink',message:'Review',candidates:[id],recipient:'Graham',adapterID:'slack'};
 assert.throws(()=>validateTextProposal(sharing,proposal));
 const slackInput={...sharing,adapters:[{id:'slack',name:'Slack',capability:'shareLink'}]};
 assert.equal(validateTextProposal(slackInput,proposal).adapterID,'slack');
 assert.throws(()=>validateTextProposal(slackInput,{...proposal,adapterID:'messages'}));
});
test('unspecified app resolves destinations locally instead of assuming a provider', () => {
 const proposal={intent:'shareLink',message:'Find Kyle',candidates:[id],recipient:'Kyle',adapterID:null};
 assert.equal(validateTextProposal(sharing,proposal).adapterID,null);
});

test('inspection is a read-only intent with bounded real targets and no recipient', () => {
 const proposal = {intent:'inspect',message:'Inspect workspace metadata',candidates:[id],recipient:null,adapterID:null};
 assert.equal(validateTextProposal({...sharing,text:'What directory is this workspace in?'},proposal).intent,'inspect');
 assert.throws(() => validateTextProposal(sharing,{...proposal,recipient:'Someone'}));
 assert.throws(() => validateTextProposal(sharing,{...proposal,adapterID:'messages'}));
 assert.throws(() => validateTextProposal(sharing,{...proposal,candidates:['49d10d29-e2e6-47d6-bd89-59ed954bf3a1']}));
});
