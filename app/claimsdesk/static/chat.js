// Claims Desk assistant drawer (stage 5). Talks to nginx /chat/, which proxies the chat pods.
// The conversation lives in sessionStorage only; the server keeps no history.
(function () {
  "use strict";
  var KEY = "claimsdesk.chat";
  var body = document.body;
  var log = document.getElementById("chat-log");
  var form = document.getElementById("chat-form");
  var input = document.getElementById("chat-input");
  var send = document.getElementById("chat-send");
  var starters = document.getElementById("chat-starters");
  var model = document.getElementById("chat-model");
  var history = [];
  var busy = false;

  try { history = JSON.parse(sessionStorage.getItem(KEY) || "[]"); } catch (e) { history = []; }

  function save() { sessionStorage.setItem(KEY, JSON.stringify(history.slice(-40))); }

  function esc(s) {
    return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
  }

  function inline(s) {
    return esc(s)
      .replace(/`([^`]+)`/g, "<code>$1</code>")
      .replace(/\*\*([^*]+)\*\*/g, "<b>$1</b>")
      .replace(/\b(CLM-\d{1,12})\b/g, '<a href="/claims/$1">$1</a>')
      .replace(/\b(high|medium)\b(?=\)|\s*risk|\s*\||$)/gi, function (m) {
        return '<span class="risk-' + m.toLowerCase() + '">' + m + "</span>";
      });
  }

  // Enough Markdown for the model's answers: paragraphs, lists, tables, code blocks.
  function markdown(text) {
    var lines = text.replace(/\r/g, "").split("\n");
    var out = [], i = 0;
    while (i < lines.length) {
      var line = lines[i];
      if (/^```/.test(line)) {
        var code = [];
        i++;
        while (i < lines.length && !/^```/.test(lines[i])) { code.push(lines[i]); i++; }
        i++;
        out.push("<pre>" + esc(code.join("\n")) + "</pre>");
        continue;
      }
      if (/^\s*\|.*\|\s*$/.test(line)) {
        var rows = [];
        while (i < lines.length && /^\s*\|.*\|\s*$/.test(lines[i])) { rows.push(lines[i]); i++; }
        var html = "<table>";
        rows.forEach(function (r, n) {
          if (/^\s*\|[\s:|-]+\|\s*$/.test(r)) { return; }
          var cells = r.trim().replace(/^\||\|$/g, "").split("|");
          var tag = n === 0 ? "th" : "td";
          html += "<tr>" + cells.map(function (c) { return "<" + tag + ">" + inline(c.trim()) + "</" + tag + ">"; }).join("") + "</tr>";
        });
        out.push(html + "</table>");
        continue;
      }
      if (/^\s*([-*]|\d+\.)\s+/.test(line)) {
        var ordered = /^\s*\d+\./.test(line), items = [];
        while (i < lines.length && /^\s*([-*]|\d+\.)\s+/.test(lines[i])) {
          items.push("<li>" + inline(lines[i].replace(/^\s*([-*]|\d+\.)\s+/, "")) + "</li>");
          i++;
        }
        out.push((ordered ? "<ol>" : "<ul>") + items.join("") + (ordered ? "</ol>" : "</ul>"));
        continue;
      }
      if (/^#{1,6}\s+/.test(line)) { out.push("<p><b>" + inline(line.replace(/^#+\s+/, "")) + "</b></p>"); i++; continue; }
      if (line.trim()) { out.push("<p>" + inline(line) + "</p>"); }
      i++;
    }
    return out.join("");
  }

  function bubble(role, text) {
    var div = document.createElement("div");
    div.className = "chat-msg " + role;
    if (role === "assistant") {
      div.innerHTML = markdown(text);
      addCopy(div, text);
    } else {
      div.textContent = text;
    }
    log.appendChild(div);
    log.scrollTop = log.scrollHeight;
    return div;
  }

  function addCopy(div, text) {
    var b = document.createElement("button");
    b.type = "button";
    b.className = "copy";
    b.textContent = "copy";
    b.onclick = function () {
      navigator.clipboard && navigator.clipboard.writeText(text);
      b.textContent = "copied";
    };
    div.insertBefore(b, div.firstChild);
  }

  function render() {
    starters.style.display = history.length ? "none" : "";
    history.forEach(function (m) { bubble(m.role, m.content); });
  }

  function open() {
    body.classList.add("chat-open");
    input.focus();
    fetch("/chat/health").then(function (r) { return r.json(); }).then(function (h) {
      var llm = h.llm || {};
      model.textContent = (llm.model || "?") + " + " + (llm.vision_model || "?") + " · read-only";
      if (h.status !== "ok") {
        model.textContent += " · " + (llm.error || (h.api && h.api.status) || "degraded");
      }
    }).catch(function () { model.textContent = "Assistant unavailable"; });
  }

  // Server-sent events over a POST body, so fetch and a reader instead of EventSource.
  function stream(messages, onEvent) {
    return fetch("/chat/v1/messages", {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({messages: messages})
    }).then(function (r) {
      if (!r.ok || !r.body) { throw new Error("Assistant unavailable (HTTP " + r.status + ")"); }
      var reader = r.body.getReader(), dec = new TextDecoder(), buf = "";
      function pump() {
        return reader.read().then(function (res) {
          if (res.done) { return; }
          buf += dec.decode(res.value, {stream: true});
          var at;
          while ((at = buf.indexOf("\n\n")) >= 0) {
            var block = buf.slice(0, at), ev = "message", data = "";
            buf = buf.slice(at + 2);
            block.split("\n").forEach(function (l) {
              if (l.indexOf("event:") === 0) { ev = l.slice(6).trim(); }
              if (l.indexOf("data:") === 0) { data += l.slice(5).trim(); }
            });
            try { onEvent(ev, JSON.parse(data || "{}")); } catch (e) { /* ignore a broken event */ }
          }
          return pump();
        });
      }
      return pump();
    });
  }

  function ask(text) {
    if (busy || !text.trim()) { return; }
    busy = true;
    send.disabled = true;
    starters.style.display = "none";
    history.push({role: "user", content: text});
    save();
    bubble("user", text);
    var tools = document.createElement("div");
    tools.className = "chat-tools";
    log.appendChild(tools);
    var answer = null, acc = "", chips = {};
    stream(history, function (ev, d) {
      if (ev === "tool") {
        var chip = chips[d.id];
        if (!chip) {
          chip = chips[d.id] = document.createElement("div");
          tools.appendChild(chip);
        }
        chip.className = "chat-tool " + (d.state === "start" ? "run" : (d.ok ? "" : "fail"));
        chip.textContent = d.state === "start" ? d.name + " …" : d.summary;
      } else if (ev === "delta") {
        if (!answer) { answer = bubble("assistant", ""); }
        acc += d.text;
        answer.innerHTML = markdown(acc);
      } else if (ev === "error") {
        bubble("error", d.message || "Assistant error");
      } else if (ev === "done" && answer) {
        addCopy(answer, acc);
      }
      log.scrollTop = log.scrollHeight;
    }).catch(function (e) {
      bubble("error", e.message || "Assistant unavailable");
    }).then(function () {
      if (acc) { history.push({role: "assistant", content: acc}); save(); }
      busy = false;
      send.disabled = false;
      input.focus();
    });
  }

  document.getElementById("chat-toggle").onclick = open;
  document.getElementById("chat-close").onclick = function () { body.classList.remove("chat-open"); };
  document.getElementById("chat-clear").onclick = function () {
    history = [];
    save();
    Array.prototype.slice.call(log.querySelectorAll(".chat-msg, .chat-tools")).forEach(function (n) { n.remove(); });
    starters.style.display = "";
  };
  Array.prototype.forEach.call(starters.querySelectorAll("button"), function (b) {
    b.onclick = function () { ask(b.textContent); };
  });
  form.onsubmit = function (e) {
    e.preventDefault();
    var text = input.value;
    input.value = "";
    ask(text);
  };
  input.addEventListener("keydown", function (e) {
    if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); form.onsubmit(e); }
  });
  render();
  if (history.length) { open(); }
})();
