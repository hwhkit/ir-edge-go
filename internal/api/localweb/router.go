// Package localweb 实现 Node Console（127.0.0.1:7800）：REST API + 内嵌单页 UI。
//
// REST API：
//
//	GET /api/status   — daemon 概览（server、版本、agents 状态）
//	GET /api/agents   — 全部智能体运行态列表
//	GET /api/agents/{slug} — 单个智能体详情
package localweb

import (
	"encoding/json"
	"net/http"
	"time"

	"ir-edge/internal/app/daemon"
)

// Handler 是 Node Console 的 HTTP 处理器。
type Handler struct {
	daemon *daemon.Daemon
	start  time.Time
}

// NewHandler .
func NewHandler(d *daemon.Daemon) *Handler {
	return &Handler{daemon: d, start: time.Now()}
}

// Router 返回 http.Handler（API + UI）。
func (h *Handler) Router() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/status", h.status)
	mux.HandleFunc("GET /api/agents", h.agents)
	mux.HandleFunc("GET /api/agents/{slug}", h.agentDetail)
	mux.HandleFunc("GET /", h.ui)
	return mux
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	json.NewEncoder(w).Encode(v)
}

func (h *Handler) status(w http.ResponseWriter, r *http.Request) {
	cfg := h.daemon.Config()
	writeJSON(w, map[string]any{
		"server":      cfg.Server,
		"cluster":     cfg.Cluster,
		"port":        cfg.Port,
		"uptime":      time.Since(h.start).String(),
		"agent_count": len(cfg.Agents),
		"timestamp":   time.Now().Format(time.RFC3339),
	})
}

func (h *Handler) agents(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, map[string]any{"agents": h.daemon.State().Snapshot()})
}

func (h *Handler) agentDetail(w http.ResponseWriter, r *http.Request) {
	slug := r.PathValue("slug")
	for _, a := range h.daemon.State().Snapshot() {
		if a.Slug == slug {
			writeJSON(w, a)
			return
		}
	}
	http.Error(w, `{"error":"not found"}`, 404)
}

func (h *Handler) ui(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Write([]byte(nodeConsoleHTML))
}

// nodeConsoleHTML 是内嵌的 Node Console 单页应用。
const nodeConsoleHTML = `<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>IR Node Console</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font:14px/1.5 -apple-system,'Segoe UI','PingFang SC',sans-serif;background:#111418;color:#f2f4f7;padding:24px}
h1{font-size:22px;margin-bottom:4px;background:linear-gradient(180deg,#f2f4f7,#cdd5de);-webkit-background-clip:text;-webkit-text-fill-color:transparent}
.sub{color:#8a939e;font-size:12px;margin-bottom:24px}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(300px,1fr));gap:16px}
.card{border:1px solid rgba(186,194,203,.15);border-radius:12px;padding:16px;background:rgba(23,27,32,.9)}
.card h2{font-size:14px;color:#cdd5de;margin-bottom:8px}
.card .meta{font-size:11px;color:#8a939e;margin-bottom:12px}
.stat{display:inline-block;margin:0 16px 8px 0}
.stat b{display:block;font-size:20px;color:#f2f4f7}
.stat span{font-size:10px;color:#8a939e;text-transform:uppercase}
.runs{margin-top:12px;font-size:11px;font-family:monospace}
.run{display:flex;justify-content:space-between;padding:4px 0;border-top:1px solid rgba(186,194,203,.1)}
.run .ok{color:#75efba}.run .fail{color:#ff8f96}
pre{background:rgba(0,0,0,.3);border-radius:6px;padding:8px;font-size:10px;overflow-x:auto;margin-top:8px;max-height:120px}
.refresh{position:fixed;bottom:20px;right:20px;padding:8px 16px;border:1px solid rgba(186,194,203,.3);border-radius:8px;background:rgba(23,27,32,.95);color:#cdd5de;cursor:pointer;font-size:12px}
</style>
</head>
<body>
<h1>IR Node Console</h1>
<p class="sub" id="sub">loading…</p>
<div class="grid" id="grid"></div>
<button class="refresh" onclick="load()">刷新</button>
<script>
async function load(){
  try{
    const [st, ag] = await Promise.all([
      fetch('/api/status').then(r=>r.json()),
      fetch('/api/agents').then(r=>r.json())
    ]);
    document.getElementById('sub').textContent =
      st.server + ' · cluster=' + st.cluster + ' · uptime=' + st.uptime;
    const grid = document.getElementById('grid');
    grid.innerHTML = '';
    (ag.agents||[]).forEach(a=>{
      const c = document.createElement('div');
      c.className='card';
      const runs = (a.Runs||a.runs||[]).slice(-5).map(r=>
        '<div class="run"><span>'+r.RunID.slice(0,20)+'</span><span class="'+(r.Status==='succeeded'?'ok':'fail')+'">'+r.Status+'</span><span>'+r.DurationMs+'ms</span></div>'
      ).join('');
      c.innerHTML = '<h2>'+(a.Online?'<span style="color:#75efba">●</span> ':'<span style="color:#ff8f96">●</span> ')+a.Slug+'</h2>'
        +'<div class="meta">capacity='+a.Capacity+' inflight='+a.InFlight+'</div>'
        +'<div class="stat"><b>'+((a.Runs||a.runs||[]).length)+'</b><span>runs</span></div>'
        +'<div class="stat"><b>'+(a.LastError?'ERR':'OK')+'</b><span>last</span></div>'
        +'<div class="runs">'+runs+'</div>';
      grid.appendChild(c);
    });
  }catch(e){document.getElementById('sub').textContent='error: '+e}
}
load(); setInterval(load, 5000);
</script>
</body>
</html>`
