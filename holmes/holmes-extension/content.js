// Holmes Gmail content script
// Watches for compose windows and sends context to the Holmes local server

const HOLMES_URL = "http://localhost:5766/context";
let lastSent = "";
let pollInterval = null;

function getComposeData() {
  // Gmail compose selectors (works in both Gmail and Comet)
  const composeWindows = document.querySelectorAll('[role="dialog"], .nH.Hd, .AD');
  
  for (const win of composeWindows) {
    const toField = win.querySelector('[name="to"], [data-hovercard-id], .vO');
    const subjectField = win.querySelector('[name="subjectbox"], input[placeholder="Subject"]');
    const bodyField = win.querySelector('[role="textbox"][aria-label*="Body"], .Am.Al.editable, [contenteditable="true"]');

    const to = toField?.value || toField?.innerText || toField?.getAttribute("data-hovercard-id") || "";
    const subject = subjectField?.value || "";
    const body = bodyField?.innerText || "";

    // Also grab recipient chips
    const chips = [...win.querySelectorAll('.vN.bfK span[email], [data-hovercard-id]')]
      .map(el => el.getAttribute("email") || el.getAttribute("data-hovercard-id") || el.innerText)
      .filter(Boolean)
      .join(", ");

    const recipient = chips || to;

    if (subject || recipient || body.length > 5) {
      return { type: "gmail_compose", recipient, subject, body, url: location.href };
    }
  }
  return null;
}

function getEmailViewData() {
  // Reading an email
  const sender = document.querySelector('.gD')?.getAttribute("email") || 
                 document.querySelector('.go')?.innerText || "";
  const subject = document.querySelector('h2.hP')?.innerText || document.title.replace(" - Gmail", "");
  const body = document.querySelector('.a3s.aiL')?.innerText?.slice(0, 800) || "";

  if (sender || body) {
    return { type: "gmail_read", sender, subject, body, url: location.href };
  }
  return null;
}

function getCurrentContext() {
  return getComposeData() || getEmailViewData() || {
    type: "gmail_inbox",
    url: location.href,
    title: document.title
  };
}

function sendToHolmes(data) {
  const key = JSON.stringify(data);
  if (key === lastSent) return;
  lastSent = key;

  // Use XHR — fetch is blocked for http://localhost from https pages in some browsers
  const xhr = new XMLHttpRequest();
  xhr.open("POST", HOLMES_URL, true);
  xhr.setRequestHeader("Content-Type", "application/json");
  xhr.timeout = 2000;
  xhr.onload = () => console.log("[Holmes] Sent context:", data.type, data.subject);
  xhr.onerror = () => console.log("[Holmes] Could not reach Holmes app — is it running?");
  xhr.send(JSON.stringify(data));
}

function poll() {
  const ctx = getCurrentContext();
  if (ctx) sendToHolmes(ctx);
}

// Poll every 3 seconds
pollInterval = setInterval(poll, 3000);
poll(); // immediate first run

// Also fire on DOM mutations (compose window opening)
const observer = new MutationObserver(() => {
  setTimeout(poll, 300);
});
observer.observe(document.body, { childList: true, subtree: true });
