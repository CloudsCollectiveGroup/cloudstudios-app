"""Lokaler Testserver: liefert web/ aus und spielt Supabase-RPC gegen die lokale Test-Datenbank nach."""
import json, sys, http.server, psycopg2, psycopg2.extras, pathlib, decimal, datetime
ROOT = pathlib.Path(__file__).resolve().parents[2]
DSN = "host=/tmp port=5433 user=postgres dbname=cs_test"
db = psycopg2.connect(DSN); db.autocommit = True

def wert(v):
    if isinstance(v, decimal.Decimal): return float(v)
    if isinstance(v, (datetime.date, datetime.datetime)): return v.isoformat()
    return v

class H(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **k): super().__init__(*a, directory=str(ROOT / 'docs'), **k)
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path.startswith('/config.js'):
            self.send_response(200); self.send_header('Content-Type', 'application/javascript'); self.end_headers()
            self.wfile.write(b"window.CS_CONFIG={url:'http://test',key:'test'};"); return
        if self.path.startswith('/mock.js'):
            self.send_response(200); self.send_header('Content-Type', 'application/javascript'); self.end_headers()
            self.wfile.write((ROOT / 'tests/web/mock.js').read_bytes()); return
        if self.path.startswith('/test.html'):
            html = (ROOT / 'docs/index.html').read_text().replace('https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.49.4/dist/umd/supabase.min.js', 'mock.js')
            self.send_response(200); self.send_header('Content-Type', 'text/html; charset=utf-8'); self.end_headers(); self.wfile.write(html.encode()); return
        return super().do_GET()
    def do_POST(self):
        name = self.path.split('/rpc/')[1]
        uid = self.headers.get('X-User')
        args = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))) or b'{}')
        c = psycopg2.connect(DSN); c.autocommit = True
        try:
            with c.cursor() as k:
                k.execute("set role authenticated"); k.execute("select set_config('request.jwt.claim.sub', %s, false)", (uid,))
                k.execute("select proretset from pg_proc where proname=%s and pronamespace='public'::regnamespace limit 1", (name,))
                srf = k.fetchone()[0]
                teile = ', '.join(f"{n} => %s" for n in args)
                vals = [psycopg2.extras.Json(v) if isinstance(v, dict) else v for v in args.values()]
                if srf:
                    k.execute(f"select * from {name}({teile})", vals); cols = [d[0] for d in k.description]
                    data = [{c2: wert(v) for c2, v in zip(cols, r)} for r in k.fetchall()]
                else:
                    k.execute(f"select {name}({teile})", vals); r = k.fetchone(); data = wert(r[0]) if r else None
            body = json.dumps({'data': data, 'error': None}, default=str)
        except psycopg2.Error as e:
            body = json.dumps({'data': None, 'error': {'message': (e.pgerror or str(e)).split('\n')[0].replace('ERROR:  ', '')}})
        finally: c.close()
        self.send_response(200); self.send_header('Content-Type', 'application/json'); self.end_headers(); self.wfile.write(body.encode())

http.server.ThreadingHTTPServer(('127.0.0.1', int(sys.argv[1]) if len(sys.argv) > 1 else 8765), H).serve_forever()
