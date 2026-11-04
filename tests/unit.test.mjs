import assert from "node:assert/strict";
import test from "node:test";
import { classifyDelivery, validateInquiry, validateUpdate } from "../src/logic.mjs";

test("normalizes a valid inquiry",()=>{
 const r=validateInquiry({name:"  Jordan   Lee ",email:" JORDAN@EXAMPLE.TEST ",service:"Website",message:" Please  build a new site. "});
 assert.equal(r.valid,true);assert.equal(r.data.name,"Jordan Lee");assert.equal(r.data.email,"jordan@example.test");
 assert.equal(r.data.message,"Please build a new site.");
});
test("rejects invalid name, email, service, and message",()=>{
 const r=validateInquiry({name:"A",email:"not-an-email",service:"Other",message:"Hi"});
 assert.equal(r.valid,false);assert.equal(r.errors.length,4);
});
test("rejects non-string form data",()=>{
 assert.equal(validateInquiry({name:{},email:[],service:null,message:3}).valid,false);
});
test("accepts only UUIDs and supported status changes",()=>{
 const id="550e8400-e29b-41d4-a716-446655440000";
 assert.equal(validateUpdate({inquiry_id:id,status:"contacted"}).valid,true);
 assert.equal(validateUpdate({inquiry_id:"../../settings",status:"delete"}).valid,false);
});
test("requires a provider ID to call delivery successful",()=>{
 assert.equal(classifyDelivery({statusCode:200,body:{id:"email_123"}}).success,true);
 assert.equal(classifyDelivery({statusCode:204,body:{}}).success,false);
});
test("retries temporary errors but not invalid credentials",()=>{
 assert.equal(classifyDelivery({statusCode:429,body:{name:"rate_limit_exceeded"}}).transient,true);
 assert.equal(classifyDelivery({statusCode:503,body:{}}).transient,true);
 assert.equal(classifyDelivery({statusCode:401,body:{name:"invalid_api_key"}}).transient,false);
});
test("caps Retry-After and does not store private response bodies",()=>{
 const r=classifyDelivery({statusCode:429,headers:{"retry-after":"999999"},body:{message:"customer@example.test"}});
 assert.equal(r.retry_after_seconds,86400);assert.equal(r.error.includes("customer@example.test"),false);
});
test("keeps transport errors uncertain without exposing raw content",()=>{
 const r=classifyDelivery({statusCode:0,error:"private response content"});
 assert.equal(r.transient,true);assert.equal(r.error.includes("private response content"),false);
});
