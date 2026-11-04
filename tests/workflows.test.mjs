import assert from "node:assert/strict";
import fs from "node:fs/promises";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),"..");
const files=["intake.json","status-update.json","scheduler.json","email-delivery.json"];
const workflows=Object.fromEntries(await Promise.all(files.map(async n=>[n,JSON.parse(await fs.readFile(path.join(root,"workflows",n),"utf8"))])));
test("exports four inactive workflows with valid Singapore-time graphs",()=>{
 assert.equal(Object.keys(workflows).length,4);
 for(const w of Object.values(workflows)){
  assert.equal(w.active,false);assert.equal(w.settings.timezone,"Asia/Singapore");
  const names=new Set(w.nodes.map(n=>n.name));assert.equal(names.size,w.nodes.length);
  for(const[from,channel]of Object.entries(w.connections)){
   assert.ok(names.has(from));
   for(const outputs of Object.values(channel))for(const targets of outputs)for(const target of targets)assert.ok(names.has(target.node));
  }
  for(const n of w.nodes)if(n.type==="n8n-nodes-base.httpRequest"){
   assert.equal(n.parameters.authentication,"genericCredentialType");assert.ok(n.credentials.httpCustomAuth);
  }
 }
});
test("validates customer input before database submission",()=>{
 const n=workflows["intake.json"].nodes.map(n=>n.name);
 assert.ok(n.indexOf("Validate and normalize")<n.indexOf("Save inquiry and queue alert"));
 const form=workflows["intake.json"].nodes.find(n=>n.type==="n8n-nodes-base.formTrigger");
 assert.equal(form.parameters.options.path,"inquiryflow-intake");
});
test("protects status updates with Basic Auth and restricts allowed values",()=>{
 const nodes=workflows["status-update.json"].nodes;const t=nodes.find(n=>n.type==="n8n-nodes-base.formTrigger");
 assert.equal(t.parameters.authentication,"basicAuth");assert.ok(t.credentials.httpBasicAuth);
 assert.equal(t.parameters.options.path,"inquiryflow-staff");
 const c=nodes.find(n=>n.name==="Validate staff update").parameters.jsCode;
 assert.match(c,/contacted/);assert.match(c,/closed/);
});
test("preserves schedules and Resend idempotency and transport-error handling",()=>{
 assert.equal(workflows["scheduler.json"].nodes[0].parameters.rule.interval[0].expression,"*/5 * * * *");
 assert.equal(workflows["email-delivery.json"].nodes[0].parameters.rule.interval[0].expression,"* * * * *");
 const send=workflows["email-delivery.json"].nodes.find(n=>n.name==="Send email via Resend");
 assert.equal(send.parameters.headerParameters.parameters[0].name,"Idempotency-Key");
 assert.equal(send.onError,"continueRegularOutput");
});
