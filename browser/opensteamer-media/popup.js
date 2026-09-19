"use strict";
const status = document.getElementById("status");
const permission = document.getElementById("permission");
const authorize = document.getElementById("authorize");
chrome.runtime.sendMessage({ v: 1, type: "status" }).then(result => {
  status.textContent = result?.connected ? (result.source ? `Connected · ${result.source}` : "Connected · No active YouTube video") : "opensteamer media helper is unavailable.";
}).catch(() => { status.textContent = "opensteamer media helper is unavailable."; });
authorize.addEventListener("click", async () => {
  authorize.disabled = true;
  permission.textContent = "Waiting for the macOS permission choice…";
  try {
    const id = crypto.randomUUID();
    const result = await chrome.runtime.sendMessage({ v: 1, type: "authorizeMusic", id });
    permission.textContent = result?.id !== id ? "Music controls are unavailable." : result.result === "authorized" ? "Music controls are enabled." : result.result === "denied" ? "Music permission was denied. You can review it in System Settings → Privacy & Security → Automation." : "Music controls are unavailable.";
  } catch { permission.textContent = "Music controls are unavailable."; }
  finally { authorize.disabled = false; }
});
