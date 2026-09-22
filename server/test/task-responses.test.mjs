import test from 'node:test';
import assert from 'node:assert/strict';
import { responsesTaskBody, responsesTaskMessage } from '../lib/llm.mjs';
test('Muse tool calls and results retain call IDs across turns', () => {
 const body = responsesTaskBody({model:'muse-spark-1.3-contributor',messages:[
  {role:'system',content:'Use sources'}, {role:'user',content:'Find cafes'},
  {role:'assistant',content:null,tool_calls:[{id:'call_1',function:{name:'web_search',arguments:'{"query":"cafes"}'}}]},
  {role:'tool',tool_call_id:'call_1',content:'{"results":[]}'},
 ],tools:[{type:'function',function:{name:'web_search',parameters:{type:'object',properties:{query:{type:'string'}}}}}], reasoning:'medium'});
 assert.equal(body.instructions,'Use sources');
 assert.equal(body.input[1].type,'function_call');
 assert.equal(body.input[2].type,'function_call_output');
 assert.equal(body.input[1].call_id,body.input[2].call_id);
 assert.equal(body.tools[0].name,'web_search');
 assert.deepEqual(body.reasoning,{effort:'medium'});
});
test('tool-only responses are real work, not missing messages', () => {
 const message=responsesTaskMessage({status:'completed',output:[{type:'function_call',call_id:'call_1',name:'web_search',arguments:'{}'}]});
 assert.equal(message.tool_calls[0].id,'call_1'); assert.equal(message.content,null);
});
test('final JSON and incomplete output remain distinct', () => {
 assert.equal(responsesTaskMessage({status:'completed',output:[{type:'message',content:[{type:'output_text',text:'{"summary":"done"}'}]}]}).content,'{"summary":"done"}');
 assert.equal(responsesTaskMessage({status:'incomplete',output:[]}),null);
 assert.equal(responsesTaskMessage({output:[]}),null);
 const body=responsesTaskBody({model:'muse',messages:[],json:true,maxTokens:4000});
 assert.deepEqual(body.text,{format:{type:'json_object'}});assert.equal(body.max_output_tokens,4000);
});
