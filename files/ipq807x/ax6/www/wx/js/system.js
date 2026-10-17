import{c as t}from"./index.js";
/**
 * @license lucide-vue-next v0.563.0 - ISC
 *
 * This source code is licensed under the ISC license.
 * See the LICENSE file in the root directory of this source tree.
 */const n=t("circle-check",[["circle",{cx:"12",cy:"12",r:"10",key:"1mglay"}],["path",{d:"m9 12 2 2 4-4",key:"dzmm74"}]]);async function a(t,n="GET",a,o){const e=localStorage.getItem("wx_auth_token"),c={};e&&(c.Authorization=e),a&&(c["Content-Type"]="application/json");const r=await fetch(`/cgi-bin/wx-auth.sh?action=${t}`,{method:n,headers:c,body:a?JSON.stringify(a):void 0,signal:o});return await r.json()}async function o(){return a("reboot","POST")}async function e(){return a("checkUpdate","POST")}async function c(){return a("doUpdate","POST")}async function r(t,n){const o=new AbortController,e=window.setTimeout(()=>o.abort(),15e3);try{return await a("change","POST",{oldPassword:t,newPassword:n},o.signal)}finally{window.clearTimeout(e)}}export{n as C,e as a,r as c,c as d,o as r};
