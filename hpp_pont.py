#!/usr/bin/env python3
"""HPP Pont: expose un serveur MCP stdio (tbp-mcp) en Streamable HTTP, protege par OAuth 2.1.

Bibliotheque standard seulement. Ecoute sur 127.0.0.1 uniquement.
Le tunnel HTTPS (cloudflared) se branche devant.

Usage:
  python hpp_pont.py --set-pin            # choisir le code d'approbation (saisie masquee)
  python hpp_pont.py -- tbp-mcp           # lancer le pont devant la commande donnee
  python hpp_pont.py --revoke-all         # invalider tous les jetons emis
"""
import argparse, base64, getpass, hashlib, hmac, html, json, os, secrets, socket, subprocess
import signal, sys, threading, time, urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOME = os.path.expanduser(os.environ.get("HPP_PONT_DIR", "~/.hpp-pont"))
STATE = os.path.join(HOME, "etat.json")
LOG = os.path.join(HOME, "pont.log")
ACCESS_TTL = 3600
REFRESH_TTL = 30 * 86400
CODE_TTL = 300
MAX_BODY = 5 * 1024 * 1024
REQ_TIMEOUT = 180
PROTO = "2025-06-18"
CAPTURES = {"browser_screenshot", "browser_screenshot_element", "browser_screenshot_annotate"}
CAPT_DIR = os.path.join(HOME, "captures")
IMG_MAX = 3_700_000
# Outils qui peuvent passer par le clavier ou la souris de l'ecran X11 (xdotool, presse-papiers) :
# ils agiraient sur l'onglet affiche, pas forcement sur l'onglet de travail.
GARDES = {"browser_click", "browser_dblclick", "browser_type", "browser_type_otp", "browser_press",
          "browser_swipe", "browser_drag", "browser_mouse_move", "browser_hover", "browser_tab_to",
          "browser_focus", "browser_form_fill", "browser_select", "browser_check", "browser_waitact",
          "browser_macro", "browser_iframe_click", "browser_shadow_click", "browser_upload"}
SAISIE = {"browser_type", "browser_form_fill", "browser_type_otp"}
DELAI_REPARATION = 120
ECRAN_NUM = os.environ.get("HPP_ECRAN", ":99")
VNC_PORT = int(os.environ.get("HPP_VNC_PORT", "5900"))
RECONNEXION = "Dans Termux : bash ~/hpp-pont/ecran.sh"
SONDE = ("JSON.stringify({v: document.visibilityState, u: location.href, t: document.title})")
OUTIL_REPARER = {
    "name": "hpp_reparer",
    "description": ("Repare le pilotage du navigateur HPP sans aucune intervention humaine. A appeler des qu'un "
                    "outil browser_* echoue par delai depasse, renvoie une page vide, ou que les commandes "
                    "apparaissent dans la barre d'adresse. Arrete le demon et son Firefox, redemarre le pilote, "
                    "puis remet l'affichage VNC et la correction clavier sur le nouvel ecran. L'ecran de "
                    "l'utilisateur revient tout seul, dans le meme geste : aucune commande a lui demander. "
                    "Les sessions connectees sont conservees : le profil Firefox n'est jamais supprime. "
                    "A savoir avant d'appeler : la reparation coupe aussi l'acces de ChatGPT au navigateur "
                    "pendant quelques secondes, le temps que le demon partage redemarre. Ne pas l'appeler "
                    "pour une simple page lente."),
    "inputSchema": {"type": "object", "properties": {}},
}
MIMES = {".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".webp": "image/webp"}
HOSTED_CALLBACKS = {"https://claude.ai/api/mcp/auth_callback", "https://claude.com/api/mcp/auth_callback"}

_lock = threading.RLock()
_ecran_lock = threading.RLock()


def log(msg):
    os.makedirs(HOME, exist_ok=True)
    with open(LOG, "a") as f:
        f.write(time.strftime("%Y-%m-%d %H:%M:%S ") + msg + "\n")


def port_ouvert(port, hote="127.0.0.1", delai=2.0):
    """Vrai seulement si quelque chose accepte vraiment une connexion sur ce port."""
    try:
        with socket.create_connection((hote, port), delai):
            return True
    except OSError:
        return False


def ecran_present():
    """Vrai si l'ecran virtuel existe. C'est lui qui porte Firefox et l'affichage VNC."""
    num = ECRAN_NUM.lstrip(":")
    prefix = os.environ.get("PREFIX", "/data/data/com.termux/files/usr")
    for chemin in ("/tmp/.X11-unix/X" + num, os.path.join(prefix, "tmp/.X11-unix/X" + num)):
        if os.path.exists(chemin):
            return True
    try:
        return subprocess.run(["pgrep", "-f", "Xvfb.*:" + num],
                              capture_output=True, timeout=10).returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def rendre_ecran(attente=25):
    """Rend l'ecran a l'utilisateur apres un redemarrage du pilote.

    Attend que l'ecran virtuel revienne, puis remet x11vnc dessus s'il manque ou s'il
    ne repond plus. Rend une ligne de rapport verifiee, jamais supposee.
    """
    with _ecran_lock:
        return _rendre_ecran(attente)


def _rendre_ecran(attente):
    fin = time.monotonic() + attente
    while not ecran_present() and time.monotonic() < fin:
        time.sleep(1)
    if not ecran_present():
        return ("ecran NON revenu : l'ecran virtuel " + ECRAN_NUM + " n'existe pas. " + RECONNEXION)
    try:
        vivant = subprocess.run(["pgrep", "-x", "x11vnc"],
                                capture_output=True, timeout=10).returncode == 0
    except (OSError, subprocess.SubprocessError):
        vivant = False
    if vivant and port_ouvert(VNC_PORT):
        return f"ecran deja en marche, RealVNC repond sur 127.0.0.1:{VNC_PORT}"
    if vivant:
        # x11vnc a survecu a son ecran : il ne sert plus rien, il faut le remplacer.
        try:
            subprocess.run(["pkill", "-x", "x11vnc"], capture_output=True, timeout=10)
        except (OSError, subprocess.SubprocessError):
            pass
        time.sleep(1)
    try:
        subprocess.run(["x11vnc", "-display", ECRAN_NUM, "-localhost", "-nopw", "-forever",
                        "-shared", "-rfbport", str(VNC_PORT), "-bg",
                        "-o", os.path.join(HOME, "x11vnc.log")],
                       capture_output=True, timeout=20)
    except (OSError, subprocess.SubprocessError) as e:
        return f"ecran NON revenu : x11vnc ne se lance pas ({e}). {RECONNEXION}"
    for _ in range(12):
        time.sleep(1)
        if port_ouvert(VNC_PORT, delai=1.0):
            return (f"ecran rendu et verifie sur 127.0.0.1:{VNC_PORT} : "
                    "rouvrez RealVNC si l'image est figee")
    return (f"ecran NON revenu : x11vnc ne repond pas sur {VNC_PORT}, "
            "voir ~/.hpp-pont/x11vnc.log. " + RECONNEXION)


def h(s):
    return hashlib.sha256(s.encode()).hexdigest()


def load():
    try:
        with open(STATE) as f:
            return json.load(f)
    except FileNotFoundError:
        return {"pin": None, "clients": {}, "codes": {}, "access": {}, "refresh": {}, "fails": []}


def save(st):
    os.makedirs(HOME, mode=0o700, exist_ok=True)
    tmp = STATE + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(st, f)
    os.replace(tmp, STATE)


def purge(st):
    now = time.time()
    for k in ("codes", "access", "refresh"):
        st[k] = {t: v for t, v in st[k].items() if v["exp"] > now}
    st["fails"] = [t for t in st["fails"] if t > now - 900]


def pin_hash(pin, salt):
    return hashlib.pbkdf2_hmac("sha256", pin.encode(), bytes.fromhex(salt), 200_000).hex()


def redirect_ok(uri):
    if uri in HOSTED_CALLBACKS:
        return True
    p = urllib.parse.urlsplit(uri)
    return p.scheme == "http" and p.hostname in ("localhost", "127.0.0.1") and p.path == "/callback" and not p.query


# ---------------------------------------------------------------- processus MCP stdio
class Enfant:
    def __init__(self, cmd, bloques=()):
        self.cmd = cmd
        self.bloques = set(bloques)
        self.schemas = {}
        self.proc = None
        self.pending = {}
        self.init_result = None
        self.counter = 0
        self.wlock = threading.Lock()
        self.slock = threading.RLock()
        self.derniere_reparation = 0.0

    def _start(self):
        err = open(os.path.join(HOME, "enfant.stderr.log"), "a")
        self.proc = subprocess.Popen(self.cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=err)
        self.init_result = None
        threading.Thread(target=self._reader, args=(self.proc,), daemon=True).start()
        log(f"enfant demarre pid={self.proc.pid}")
        r = self._call({"method": "initialize", "params": {
            "protocolVersion": PROTO, "capabilities": {},
            "clientInfo": {"name": "hpp-pont", "version": "1.0"}}}, timeout=60)
        if "result" not in r:
            try:  # ne jamais laisser un pilote vivant mais non initialise, ni son Firefox orphelin
                self.proc.kill()
            except Exception:
                pass
            self.proc = None
            raise RuntimeError(f"initialize refuse: {r}")
        self.init_result = r["result"]
        self._send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        # Le pilote vient de recreer l'ecran virtuel : l'affichage de l'utilisateur doit
        # revenir dans le meme geste, sans qu'il ait une seule commande a coller.
        threading.Thread(target=lambda: log("ecran apres demarrage : " + rendre_ecran()),
                         daemon=True).start()

    def ensure(self):
        with self.slock:
            if self.proc is None or self.proc.poll() is not None or self.init_result is None:
                self._start()

    def _send(self, msg):
        data = (json.dumps(msg, separators=(",", ":")) + "\n").encode()
        with self.wlock:
            self.proc.stdin.write(data)
            self.proc.stdin.flush()

    def _reader(self, proc):
        for line in proc.stdout:
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except ValueError:
                log("sortie non JSON ignoree")
                continue
            if "method" in msg and "id" in msg:  # requete serveur vers client: non prise en charge
                self._send({"jsonrpc": "2.0", "id": msg["id"],
                            "error": {"code": -32601, "message": "non pris en charge par le pont"}})
            elif "id" in msg:
                slot = self.pending.get(msg["id"])
                if slot:
                    slot["msg"] = msg
                    slot["ev"].set()
        for slot in list(self.pending.values()):
            slot["msg"] = {"error": {"code": -32000, "message": "le processus MCP s'est arrete"}}
            slot["ev"].set()
        log(f"enfant termine code={proc.poll()}")

    def _call(self, msg, timeout=REQ_TIMEOUT):
        with self.wlock:
            self.counter += 1
            iid = f"p{self.counter}"
        slot = {"ev": threading.Event(), "msg": None}
        self.pending[iid] = slot
        try:
            self._send(dict(msg, jsonrpc="2.0", id=iid))
            if not slot["ev"].wait(timeout):
                self._send({"jsonrpc": "2.0", "method": "notifications/cancelled",
                            "params": {"requestId": iid, "reason": "delai depasse"}})
                return {"error": {"code": -32001, "message": "delai depasse"}}
            return slot["msg"]
        finally:
            self.pending.pop(iid, None)

    def memoriser(self, result):
        for t in result.get("tools", []):
            self.schemas[t.get("name")] = t.get("inputSchema") or {}

    def chemin_capture(self, params):
        """Donne a l'outil de capture un chemin autorise quand Claude n'en fournit pas."""
        params = dict(params)
        args = dict(params.get("arguments") or {})
        props = self.schemas.get(params.get("name"), {}).get("properties", {})
        if "path" in props:
            # Le chemin est impose dans tous les cas : une capture ne doit jamais pouvoir ecrire
            # sur le profil Firefox, sur etat.json ou sur un script du pont.
            os.makedirs(CAPT_DIR, exist_ok=True)
            base = os.path.basename(args.get("path") or "") or time.strftime("capture-%Y%m%d-%H%M%S.png")
            if os.path.splitext(base)[1].lower() not in MIMES:
                base += ".png"
            args["path"] = os.path.join(CAPT_DIR, base)
        params["arguments"] = args
        return params

    def sonder(self):
        """Etat de l'onglet de travail : visible ou non, adresse et titre. None si illisible."""
        r = self._call({"method": "tools/call", "params": {"name": "browser_eval", "arguments": {"expression": SONDE}}},
                       timeout=30)
        try:
            txt = r["result"]["content"][0]["text"]
            val = json.loads(txt)
            val = val.get("result", val) if isinstance(val, dict) else val
            return json.loads(val) if isinstance(val, str) else val
        except (KeyError, IndexError, TypeError, ValueError):
            return None

    def ramener_onglet(self, essais=6, secondes=45):
        """Fait defiler les onglets jusqu'a ce que l'onglet de travail soit celui affiche.

        Rend l'etat final de la sonde. Evite d'avoir a demander a l'utilisateur de toucher un onglet.
        """
        etat = self.sonder()
        if isinstance(etat, dict) and etat.get("v") == "visible":
            return etat
        fin = time.monotonic() + secondes
        for i in range(essais):
            if time.monotonic() > fin:
                log("ramener_onglet: delai global atteint")
                break
            r = self._call({"method": "tools/call",
                            "params": {"name": "browser_tab_next", "arguments": {}}}, timeout=20)
            if "result" not in r:
                log(f"ramener_onglet: browser_tab_next a echoue au tour {i + 1}")
                break
            etat = self.sonder()
            if isinstance(etat, dict) and etat.get("v") == "visible":
                log(f"onglet de travail ramene a l'ecran apres {i + 1} changement(s)")
                return etat
        return etat

    def reparer(self):
        """Remet le pilotage d'aplomb : demon, Firefox, pilote, puis l'ecran et le clavier.

        Rend un rapport texte. Chaque ligne est verifiee, jamais supposee.
        """
        lignes = []

        with self.slock:
            if self.proc is not None and self.proc.poll() is None:
                try:
                    self.proc.terminate()
                    self.proc.wait(timeout=5)
                except Exception:
                    try:
                        self.proc.kill()
                    except Exception:
                        pass
            self.proc = None
            self.init_result = None
            self.schemas = {}
        lignes.append("1. client tbp-mcp arrete")

        cibles = []
        try:
            sortie = subprocess.run(["pgrep", "-f", "firefox_profile"],
                                    capture_output=True, text=True, timeout=10).stdout.split()
            for pid in sortie:
                cibles.append(pid)
                try:
                    with open(f"/proc/{pid}/stat", encoding="utf-8", errors="replace") as fh:
                        ppid = fh.read().rsplit(")", 1)[1].split()[1]
                    protege = {"0", "1", str(os.getpid()), str(os.getppid())}
                    if ppid not in protege:
                        try:
                            with open(f"/proc/{ppid}/cmdline", "rb") as ch:
                                cl = ch.read().decode("utf-8", "replace")
                        except OSError:
                            cl = ""
                        interdits = ("bash", "/sh", "login", "cloudflared", "veilleur", "hpp_pont")
                        if any(x in cl for x in ("tbp", "firefox")) and not any(x in cl for x in interdits):
                            cibles.append(ppid)
                except OSError:
                    pass
        except (OSError, subprocess.SubprocessError) as e:
            lignes.append(f"2. recherche des processus impossible : {e}")

        cibles = [c for c in dict.fromkeys(cibles) if c.isdigit() and c != str(os.getpid())]
        for pid in cibles:
            try:
                os.kill(int(pid), signal.SIGTERM)
            except OSError:
                pass
        time.sleep(3)
        for pid in cibles:
            try:
                os.kill(int(pid), signal.SIGKILL)
            except OSError:
                pass
        lignes.append(f"2. demon et Firefox arretes ({len(cibles)} processus)" if cibles
                      else "2. aucun Firefox de pilotage trouve, rien a arreter")

        # L'ordre compte. L'ecran virtuel :99 et son x11vnc tombent avec le demon qu'on vient
        # d'arreter. Les remettre ici ne servirait a rien : le pilote va recreer l'ecran juste
        # apres. L'affichage de l'utilisateur et le clavier se refont donc EN DERNIER, une fois
        # le pilote revenu. C'est ce qui manquait le 17 septembre : l'ecran restait noir chez lui.

        try:
            self.ensure()
            lignes.append("3. pilote redemarre")
        except Exception as e:
            lignes.append(f"3. ECHEC du redemarrage du pilote : {e}")
            lignes.append("4. " + rendre_ecran())
            return "\n".join(lignes)

        try:
            r = self._call({"method": "tools/call",
                            "params": {"name": "browser_goto", "arguments": {"url": "about:blank"}}}, timeout=90)
            lignes.append("4. navigateur rouvert et pret" if "result" in r
                          else f"4. le navigateur ne repond pas encore : {r.get('error')}")
            t = self._call({"method": "tools/list", "params": {}}, timeout=60)
            if "result" in t:
                self.memoriser(t["result"])
                lignes.append(f"5. catalogue recharge ({len(self.schemas)} outils)")
        except Exception as e:
            lignes.append(f"4. verification impossible : {e}")

        # _start() a deja lance le rendu de l'ecran en arriere-plan et attendu l'ecran
        # virtuel ; ici on ne fait que confirmer, sans refaire la longue attente.
        lignes.append("6. " + rendre_ecran(attente=10))

        clavier = os.path.join(os.path.dirname(os.path.abspath(__file__)), "clavier_hpp.py")
        if os.path.exists(clavier):
            try:
                subprocess.run([sys.executable, clavier, "--si-besoin"],
                               capture_output=True, timeout=60)
                lignes.append("7. correction clavier rappliquee sur le nouvel ecran")
            except (OSError, subprocess.SubprocessError) as e:
                lignes.append(f"7. correction clavier non rappliquee : {e}")
        else:
            lignes.append("7. clavier_hpp.py absent, etape sautee")

        return "\n".join(lignes)

    def handle(self, msg):
        """Retourne une reponse JSON-RPC, ou None pour une notification."""
        if not isinstance(msg, dict) or msg.get("jsonrpc") != "2.0":
            return {"jsonrpc": "2.0", "id": None, "error": {"code": -32600, "message": "requete invalide"}}
        method = msg.get("method")
        if method is None:  # reponse du client a une requete serveur: ignoree
            return None
        if "id" not in msg:
            if method != "notifications/initialized":
                self.ensure()
                self._send({"jsonrpc": "2.0", "method": method, "params": msg.get("params", {})})
            return None
        # La reparation passe avant ensure() : c'est justement quand le pilote est mort ou fige
        # qu'on en a besoin, et ensure() bloquerait 60 secondes avant d'echouer.
        if method == "tools/call" and (msg.get("params") or {}).get("name") == OUTIL_REPARER["name"]:
            reste = DELAI_REPARATION - (time.monotonic() - self.derniere_reparation)
            if reste > 0:
                return {"jsonrpc": "2.0", "id": msg["id"], "result": {"content": [{"type": "text", "text":
                    f"Reparation deja faite il y a moins de {DELAI_REPARATION} secondes. Attendez encore "
                    f"{int(reste)} secondes, ou reessayez l'outil qui echouait : le pilote met parfois "
                    "quelques secondes a rouvrir le navigateur."}]}}
            self.derniere_reparation = time.monotonic()
            log("reparation demandee")
            try:
                rapport = self.reparer()
            except Exception as e:  # la reparation ne doit jamais tuer le pont
                log(f"reparation en echec: {e}")
                rapport = f"La reparation a echoue : {e}"
            return {"jsonrpc": "2.0", "id": msg["id"],
                    "result": {"content": [{"type": "text", "text": rapport}]}}
        self.ensure()
        if method == "initialize":
            return {"jsonrpc": "2.0", "id": msg["id"], "result": self.init_result}
        if method == "tools/call" and (msg.get("params") or {}).get("name") in self.bloques:
            log(f"outil bloque refuse: {msg['params']['name']}")
            return {"jsonrpc": "2.0", "id": msg["id"], "result": {"isError": True, "content": [
                {"type": "text", "text": "Outil bloque par le pont HPP (il toucherait le navigateur partage)."}]}}
        fwd = {"method": method}
        if "params" in msg:
            fwd["params"] = msg["params"]
        nom = (msg.get("params") or {}).get("name") if method == "tools/call" else None

        if nom in SAISIE and "mode" in (self.schemas.get(nom) or {}).get("properties", {}):
            # Saisie toujours directe : le presse-papiers ecraserait ce que l'utilisateur y a mis.
            p = dict(fwd.get("params") or {})
            a = dict(p.get("arguments") or {})
            if a.get("mode") != "xdotool":
                a["mode"] = "xdotool"
                p["arguments"] = a
                fwd["params"] = p

        etat = None
        if nom in GARDES or nom in CAPTURES:
            etat = self.ramener_onglet() if nom in GARDES else self.sonder()
        if nom in GARDES and not (isinstance(etat, dict) and etat.get("v") == "visible"):
            log(f"action refusee, onglet de travail non affiche: {nom}")
            detail = f" (onglet de travail : {etat.get('t')!r}, {etat.get('u')})" if isinstance(etat, dict) else ""
            return {"jsonrpc": "2.0", "id": msg["id"], "result": {"isError": True, "content": [{"type": "text", "text":
                "Action refusee par le pont HPP : l'onglet de travail n'est pas l'onglet affiche a l'ecran" + detail +
                ". Le pont a essaye de le ramener a l'ecran et n'y est pas arrive : un clic ou une frappe "
                "toucherait un autre onglet. Appelez hpp_reparer, puis recommencez."}]}}
        capture = nom in CAPTURES
        if capture:
            fwd["params"] = self.chemin_capture(msg["params"])
        r = self._call(fwd)
        if method == "tools/list" and "result" in r:
            self.memoriser(r["result"])
            if self.bloques:
                r["result"]["tools"] = [t for t in r["result"].get("tools", []) if t.get("name") not in self.bloques]
            outils = r["result"].setdefault("tools", [])
            if not any(t.get("name") == OUTIL_REPARER["name"] for t in outils):
                outils.append(dict(OUTIL_REPARER))
        if capture and "result" in r:
            joindre_image(r["result"])
            if isinstance(etat, dict) and etat.get("v") != "visible":
                r["result"].setdefault("content", []).append({"type": "text", "text":
                    f"Attention : la capture montre l'ecran, pas l'onglet de travail ({etat.get('t')!r}, "
                    f"{etat.get('u')}), qui n'est pas affiche."})
        out = {"jsonrpc": "2.0", "id": msg["id"]}
        if "result" in r:
            out["result"] = r["result"]
        else:
            out["error"] = r.get("error", {"code": -32603, "message": "erreur interne"})
        return out


def joindre_image(result):
    """Ajoute l'image elle-meme quand l'outil de capture ne renvoie qu'un chemin de fichier."""
    home = os.path.realpath(os.path.expanduser("~"))
    for c in list(result.get("content", [])):
        if c.get("type") != "text":
            continue
        try:
            d = json.loads(c.get("text", ""))
        except ValueError:
            continue
        chemin = d.get("path") if isinstance(d, dict) else None
        if not isinstance(chemin, str):
            continue
        rp = os.path.realpath(chemin)
        mime = MIMES.get(os.path.splitext(rp)[1].lower())
        if not mime or not rp.startswith(home + os.sep) or not os.path.isfile(rp):
            continue
        taille = os.path.getsize(rp)
        if taille > IMG_MAX:
            result["content"].append({"type": "text", "text": f"Image trop lourde pour etre jointe ({taille} octets)."})
            continue
        with open(rp, "rb") as f:
            data = base64.b64encode(f.read()).decode()
        result["content"].append({"type": "image", "data": data, "mimeType": mime})


# ---------------------------------------------------------------- HTTP
PAGE = """<!doctype html><html lang="fr"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>HPP Pont, autorisation</title>
<style>body{{font-family:system-ui,sans-serif;background:#111;color:#eee;max-width:32rem;margin:2rem auto;padding:0 1rem}}
input,button{{font-size:1.2rem;padding:.7rem;width:100%;box-sizing:border-box;margin:.4rem 0}}
button{{background:#c9a227;border:0;color:#111;font-weight:700}} .d{{color:#f88}} code{{color:#c9a227}}</style>
<h1>Autoriser l'acces au navigateur HPP</h1>
<p>Application : <b>{client}</b><br>Retour vers : <code>{host}</code></p>
{warn}<p class="d">{err}</p>
<form method="post" action="authorize">
{hidden}
<input type="password" name="pin" placeholder="Code d'approbation" autocomplete="off" required autofocus>
<button type="submit">Autoriser</button></form>
<p>Si vous n'avez pas lance cette connexion vous-meme, fermez cette page.</p></html>"""


class H(BaseHTTPRequestHandler):
    server_version = "hpp-pont"
    enfant = None
    public_url = None

    def log_message(self, fmt, *a):
        log(f"{self.command} {self.path.split('?')[0]} -> " + (fmt % a))

    def base(self):
        if self.public_url:
            return self.public_url.rstrip("/")
        host = self.headers.get("X-Forwarded-Host") or self.headers.get("Host", "127.0.0.1")
        proto = self.headers.get("X-Forwarded-Proto", "http")
        return f"{proto}://{host}"

    def send(self, code, body=b"", ctype="application/json", extra=None):
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
        elif isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n < 0 or n > MAX_BODY:
            raise ValueError("corps trop grand")
        return self.rfile.read(n)

    def form(self):
        return {k: v[0] for k, v in urllib.parse.parse_qs(self.body().decode(), keep_blank_values=True).items()}

    def oauth_err(self, code, err, desc=""):
        self.send(code, {"error": err, "error_description": desc})

    # ---- metadonnees
    def meta_resource(self):
        b = self.base()
        return {"resource": b + "/mcp", "authorization_servers": [b],
                "bearer_methods_supported": ["header"], "scopes_supported": ["navigateur"]}

    def meta_as(self):
        b = self.base()
        return {"issuer": b, "authorization_endpoint": b + "/authorize", "token_endpoint": b + "/token",
                "registration_endpoint": b + "/register", "response_types_supported": ["code"],
                "grant_types_supported": ["authorization_code", "refresh_token"],
                "code_challenge_methods_supported": ["S256"],
                "token_endpoint_auth_methods_supported": ["none"], "scopes_supported": ["navigateur"]}

    def do_GET(self):
        path = urllib.parse.urlsplit(self.path).path
        if path.startswith("/.well-known/oauth-protected-resource"):
            return self.send(200, self.meta_resource())
        if path.startswith("/.well-known/oauth-authorization-server") or path.startswith("/.well-known/openid-configuration"):
            return self.send(200, self.meta_as())
        if path == "/sante":
            return self.send(200, "ok", "text/plain")
        if path == "/authorize":
            q = {k: v[0] for k, v in urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query).items()}
            return self.authorize_page(q, "")
        if path == "/mcp":
            if not self.authed():
                return
            return self.send(405, "", "text/plain", {"Allow": "POST, DELETE"})
        self.send(404, {"error": "introuvable"})

    def do_HEAD(self):
        self.do_GET()

    def do_DELETE(self):
        if urllib.parse.urlsplit(self.path).path != "/mcp":
            return self.send(404, {"error": "introuvable"})
        if self.authed():
            self.send(200, "")

    def do_POST(self):
        path = urllib.parse.urlsplit(self.path).path
        try:
            if path == "/register":
                return self.register()
            if path == "/authorize":
                return self.authorize_post()
            if path == "/token":
                return self.token()
            if path == "/mcp":
                return self.mcp()
            self.send(404, {"error": "introuvable"})
        except ValueError as e:
            self.send(400, {"error": "invalid_request", "error_description": str(e)})

    # ---- OAuth
    def register(self):
        try:
            data = json.loads(self.body() or b"{}")
        except ValueError:
            return self.oauth_err(400, "invalid_client_metadata", "JSON invalide")
        uris = data.get("redirect_uris") or []
        if not uris or not all(isinstance(u, str) and redirect_ok(u) for u in uris):
            return self.oauth_err(400, "invalid_redirect_uri", "adresse de retour non autorisee")
        cid = secrets.token_urlsafe(24)
        name = str(data.get("client_name") or "client")[:80]
        with _lock:
            st = load()
            st["clients"][cid] = {"name": name, "uris": uris, "t": time.time()}
            if len(st["clients"]) > 200:  # garder les 200 plus recents
                keep = sorted(st["clients"].items(), key=lambda kv: kv[1]["t"])[-200:]
                st["clients"] = dict(keep)
            save(st)
        log(f"client enregistre: {name}")
        self.send(201, {"client_id": cid, "client_id_issued_at": int(time.time()), "client_name": name,
                        "redirect_uris": uris, "grant_types": ["authorization_code", "refresh_token"],
                        "response_types": ["code"], "token_endpoint_auth_method": "none"})

    def check_authz(self, q):
        st = load()
        c = st["clients"].get(q.get("client_id", ""))
        if not c:
            return None, "client inconnu"
        if q.get("redirect_uri") not in c["uris"]:
            return None, "adresse de retour non enregistree"
        if q.get("response_type") != "code":
            return None, "response_type doit etre code"
        if q.get("code_challenge_method") != "S256" or not q.get("code_challenge"):
            return None, "PKCE S256 obligatoire"
        return c, ""

    def authorize_page(self, q, err, code=200):
        c, problem = self.check_authz(q)
        if not c:
            return self.send(400, "<h1>Requete refusee</h1><p>" + html.escape(problem) + "</p>", "text/html; charset=utf-8")
        keys = ["client_id", "redirect_uri", "response_type", "code_challenge", "code_challenge_method",
                "state", "scope", "resource"]
        hidden = "".join(f'<input type="hidden" name="{k}" value="{html.escape(q[k])}">' for k in keys if k in q)
        host = urllib.parse.urlsplit(q["redirect_uri"]).netloc
        warn = ""
        if q["redirect_uri"] not in HOSTED_CALLBACKS:
            warn = '<p class="d">Retour local (Claude Code sur cet appareil). Autorisez seulement si vous venez de le lancer.</p>'
        page = PAGE.format(client=html.escape(c["name"]), host=html.escape(host), warn=warn,
                           err=html.escape(err), hidden=hidden)
        self.send(code, page, "text/html; charset=utf-8",
                  {"Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; form-action 'self' https://claude.ai https://claude.com http://localhost:* http://127.0.0.1:*; frame-ancestors 'none'",
                   "X-Frame-Options": "DENY", "Referrer-Policy": "no-referrer"})

    def authorize_post(self):
        q = self.form()
        c, problem = self.check_authz(q)
        if not c:
            return self.send(400, "<h1>Requete refusee</h1><p>" + html.escape(problem) + "</p>", "text/html; charset=utf-8")
        with _lock:
            st = load()
            purge(st)
            if len(st["fails"]) >= 5:
                save(st)
                return self.authorize_page(q, "Trop d'essais. Reessayez dans 15 minutes.", 429)
            p = st["pin"]
            ok = p is not None and hmac.compare_digest(pin_hash(q.get("pin", ""), p["salt"]), p["hash"])
            if not ok:
                st["fails"].append(time.time())
                save(st)
                log("code d'approbation errone")
                return self.authorize_page(q, "Code incorrect.", 401)
            code = secrets.token_urlsafe(32)
            st["codes"][h(code)] = {"cid": q["client_id"], "uri": q["redirect_uri"],
                                   "chal": q["code_challenge"], "exp": time.time() + CODE_TTL}
            save(st)
        log(f"autorisation accordee a {c['name']}")
        params = {"code": code}
        if "state" in q:
            params["state"] = q["state"]
        params["iss"] = self.base()
        sep = "&" if "?" in q["redirect_uri"] else "?"
        self.send(302, "", "text/plain", {"Location": q["redirect_uri"] + sep + urllib.parse.urlencode(params)})

    def issue(self, st, cid):
        at, rt = secrets.token_urlsafe(32), secrets.token_urlsafe(32)
        now = time.time()
        st["access"][h(at)] = {"cid": cid, "exp": now + ACCESS_TTL}
        st["refresh"][h(rt)] = {"cid": cid, "exp": now + REFRESH_TTL}
        return {"access_token": at, "token_type": "Bearer", "expires_in": ACCESS_TTL,
                "refresh_token": rt, "scope": "navigateur"}

    def token(self):
        ctype = self.headers.get("Content-Type", "")
        if "application/x-www-form-urlencoded" not in ctype:
            return self.oauth_err(400, "invalid_request", "form-urlencoded attendu")
        f = self.form()
        with _lock:
            st = load()
            purge(st)
            gt = f.get("grant_type")
            if gt == "authorization_code":
                rec = st["codes"].pop(h(f.get("code", "")), None)
                if not rec or rec["cid"] != f.get("client_id") or rec["uri"] != f.get("redirect_uri"):
                    save(st)
                    return self.oauth_err(400, "invalid_grant", "code invalide")
                ver = f.get("code_verifier", "")
                calc = base64.urlsafe_b64encode(hashlib.sha256(ver.encode()).digest()).rstrip(b"=").decode()
                if not ver or not hmac.compare_digest(calc, rec["chal"]):
                    save(st)
                    return self.oauth_err(400, "invalid_grant", "PKCE invalide")
                out = self.issue(st, rec["cid"])
            elif gt == "refresh_token":
                rec = st["refresh"].pop(h(f.get("refresh_token", "")), None)
                if not rec or (f.get("client_id") and f["client_id"] != rec["cid"]):
                    save(st)
                    return self.oauth_err(400, "invalid_grant", "jeton de rafraichissement invalide")
                out = self.issue(st, rec["cid"])
            else:
                return self.oauth_err(400, "unsupported_grant_type")
            save(st)
        self.send(200, out)

    def authed(self):
        auth = self.headers.get("Authorization", "")
        ok = False
        if auth.startswith("Bearer "):
            with _lock:
                st = load()
                rec = st["access"].get(h(auth[7:].strip()))
                ok = bool(rec and rec["exp"] > time.time())
        if not ok:
            rm = self.base() + "/.well-known/oauth-protected-resource/mcp"
            self.send(401, {"error": "invalid_token"}, extra={
                "WWW-Authenticate": f'Bearer resource_metadata="{rm}", scope="navigateur"'})
        return ok

    # ---- MCP
    def mcp(self):
        if not self.authed():
            return
        try:
            data = json.loads(self.body())
        except ValueError:
            return self.send(400, {"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "JSON invalide"}})
        try:
            if isinstance(data, list):
                out = [r for r in (self.enfant.handle(m) for m in data) if r is not None]
            else:
                out = self.enfant.handle(data)
        except Exception as e:  # processus absent ou casse
            log(f"erreur enfant: {e!r}")
            return self.send(502, {"jsonrpc": "2.0", "id": None,
                                   "error": {"code": -32000, "message": "serveur navigateur indisponible"}})
        if out is None or out == []:
            return self.send(202, "")
        extra = {}
        if isinstance(data, dict) and data.get("method") == "initialize":
            extra["Mcp-Session-Id"] = secrets.token_urlsafe(16)
        self.send(200, out, extra=extra)


def main():
    ap = argparse.ArgumentParser(description="Pont MCP stdio vers HTTP avec OAuth")
    ap.add_argument("--port", type=int, default=int(os.environ.get("HPP_PONT_PORT", 8765)))
    ap.add_argument("--public-url", default=os.environ.get("HPP_PONT_PUBLIC_URL"))
    ap.add_argument("--bloquer", default=os.environ.get("HPP_BLOQUER", ""),
                    help="outils interdits, separes par des virgules")
    ap.add_argument("--set-pin", action="store_true")
    ap.add_argument("--revoke-all", action="store_true")
    ap.add_argument("cmd", nargs=argparse.REMAINDER)
    a = ap.parse_args()
    os.makedirs(HOME, mode=0o700, exist_ok=True)
    if a.set_pin:
        p1 = getpass.getpass("Nouveau code (8 caracteres minimum) : ")
        p2 = getpass.getpass("Confirmez : ")
        if p1 != p2 or len(p1) < 8:
            sys.exit("Codes differents ou trop courts. Rien n'a change.")
        with _lock:
            st = load()
            salt = secrets.token_hex(16)
            st["pin"] = {"salt": salt, "hash": pin_hash(p1, salt)}
            st["access"], st["refresh"], st["codes"] = {}, {}, {}
            save(st)
        print("Code enregistre. Les anciennes connexions sont revoquees.")
        return
    if a.revoke_all:
        with _lock:
            st = load()
            st["access"], st["refresh"], st["codes"] = {}, {}, {}
            save(st)
        print("Tous les jetons sont revoques.")
        return
    cmd = a.cmd[1:] if a.cmd[:1] == ["--"] else a.cmd
    if not cmd:
        sys.exit("Indiquez la commande du serveur MCP, par exemple : python hpp_pont.py -- tbp-mcp")
    if load()["pin"] is None:
        sys.exit("Aucun code d'approbation. Lancez d'abord : python hpp_pont.py --set-pin")
    H.enfant = Enfant(cmd, [x.strip() for x in a.bloquer.split(",") if x.strip()])
    H.public_url = a.public_url
    H.enfant.ensure()
    tools = H.enfant._call({"method": "tools/list", "params": {}}, timeout=60)
    H.enfant.memoriser(tools.get("result", {}))
    n = len(tools.get("result", {}).get("tools", []))
    if H.enfant.bloques:
        print("Outils bloques : " + ", ".join(sorted(H.enfant.bloques)))
    print(f"Serveur MCP pret : {H.enfant.init_result.get('serverInfo', {}).get('name', '?')}, {n} outils.")
    signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt()))
    srv = ThreadingHTTPServer(("127.0.0.1", a.port), H)
    srv.daemon_threads = True
    print(f"Pont a l'ecoute sur http://127.0.0.1:{a.port}  (journal : {LOG})")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        if H.enfant.proc and H.enfant.proc.poll() is None:
            H.enfant.proc.terminate()
            try:
                H.enfant.proc.wait(10)
            except subprocess.TimeoutExpired:
                H.enfant.proc.kill()
        log("pont arrete")


if __name__ == "__main__":
    main()
