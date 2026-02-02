import{c as n}from"./index.js";
/**
 * @license lucide-vue-next v0.563.0 - ISC
 *
 * This source code is licensed under the ISC license.
 * See the LICENSE file in the root directory of this source tree.
 */const t=n("circle-check",[["circle",{cx:"12",cy:"12",r:"10",key:"1mglay"}],["path",{d:"m9 12 2 2 4-4",key:"dzmm74"}]]);async function a(n,t="GET",a){const c=localStorage.getItem("wx_auth_token"),o={};c&&(o.Authorization=c),a&&(o["Content-Type"]="application/json");const e=await fetch(`/cgi-bin/wx-auth.sh?action=${n}`,{method:t,headers:o,body:a?JSON.stringify(a):void 0});return await e.json()}async function c(){return a("reboot","POST")}async function o(){return a("checkUpdate","POST")}async function e(){return a("doUpdate","POST")}async function r(n,t){return a("change","POST",{oldPassword:n,newPassword:t})}export{t as C,o as a,r as c,e as d,c as r};
