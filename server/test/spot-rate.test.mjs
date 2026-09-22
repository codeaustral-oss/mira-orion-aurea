import test from 'node:test';
import assert from 'node:assert/strict';
import { spotRateQuestion, renderSpotRate } from '../lib/corridor-support.mjs';

test('spot rate reads route without an amount and retain direction', () => {
  assert.deepEqual(spotRateQuestion('Whats the FX rate of USD to BRL today'), {from:'USD',to:'BRL'});
  assert.deepEqual(spotRateQuestion('BRL to USD exchange rate?'), {from:'BRL',to:'USD'});
});
test('spot reads do not capture transfers, history, forecasts or amount quotes', () => {
  for (const text of ['book USD to BRL at this rate', 'convert USD 500 to BRL at this rate', 'USD to BRL rate yesterday', 'predict USD BRL rate tomorrow', 'send USD to BRL', 'what is the USD rate?', 'USD BRL EUR rates']) assert.equal(spotRateQuestion(text), null, text);
});
test('spot reply uses the actual table and states its source and check time', () => {
  const reply = renderSpotRate({from:'BRL',to:'USD'}, {ok:true, perUSD:{USD:1,BRL:5}, asOf:Date.UTC(2026,8,21,12),source:'test-feed'});
  assert.match(reply,/1 BRL = 0.2000 USD/);
  assert.match(reply,/test-feed.*2026-09-21 12:00 UTC/);
  assert.match(reply,/indicative/);
  assert.doesNotMatch(reply,/\b(fee|swap|live)\b/);
});
test('rate source failure never invents a quote', () => {
  assert.match(renderSpotRate({from:'USD',to:'BRL'},{ok:false}),/couldn't check/);
  assert.match(renderSpotRate({from:'USD',to:'BRL'},{ok:true,perUSD:{USD:1}}),/couldn't check/);
});
