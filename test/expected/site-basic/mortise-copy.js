(function(){if(!navigator.clipboard)return;
function say(b,t){b.textContent=t;setTimeout(function(){b.textContent="Copy";},1500);}
document.querySelectorAll("button.mt-copy").forEach(function(b){b.hidden=false;
b.addEventListener("click",function(){var c=b.parentNode.querySelector("code");
navigator.clipboard.writeText(c.innerText).then(function(){say(b,"Copied");},function(){
var r=document.createRange();r.selectNodeContents(c);var s=getSelection();s.removeAllRanges();s.addRange(r);
say(b,"Selected");});});});})();
