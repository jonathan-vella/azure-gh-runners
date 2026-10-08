import { priceOriginalEnvelope } from './temporary-identity.mjs';
const [pricing, now] = process.argv.slice(2);
console.log(JSON.stringify(priceOriginalEnvelope(JSON.parse(pricing), now)));
