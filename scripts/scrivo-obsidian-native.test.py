import json, os, pathlib, socket, subprocess, tempfile, time, urllib.request
# Run under xvfb-run/dbus-run-session and TyporaClone's e2e-native/with-wm.sh.
# Requires its debug binary and installed Nord, Catppuccin Mocha, Flexoki Light.
if not os.environ.get('DISPLAY'):
    raise SystemExit('Run this native verification under xvfb-run.')
source_dir = pathlib.Path(__file__).resolve().parent.parent
repo = pathlib.Path(os.environ.get('SCRIVO_REPO_DIR', str(pathlib.Path.home()/'Repos/TyporaClone')))
obsidian = pathlib.Path(os.environ.get('SCRIVO_OBSIDIAN_THEMES_DIR', str(pathlib.Path.home()/'Vaults/Technical Vault/.obsidian/themes')))
workspace = tempfile.TemporaryDirectory(prefix='scrivo-obsidian-native-')
config = pathlib.Path(workspace.name)
subprocess.run(['bash', '-c', 'source "$1/scripts/lib/theme-colors.sh"; source "$1/scripts/lib/scrivo-theme.sh"; scrivo_apply_theme "$1/dot_config/tauri-explorer/themes" "$2/dev.scrivo.editor" nord dark', 'scrivo-test', str(source_dir), str(config)], check=True)
(config/'document.md').write_text('# Native theme verification\n\n**Bold** *Italic* [external](https://example.com) [internal](./other.md)\n\n`inline`\n\n```js\nconst value = 42;\n```\n')
env = dict(os.environ, XDG_CONFIG_HOME=str(config), XDG_DATA_HOME=str(config/'data'))
env.pop('WAYLAND_DISPLAY', None)
env.pop('HYPRLAND_INSTANCE_SIGNATURE', None)
env['GDK_BACKEND'] = 'x11'
def port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1',0))
        return sock.getsockname()[1]
p, np = port(), port()
while np == p: np = port()
log = open(config/'driver.log', 'w')
driver = subprocess.Popen([str(pathlib.Path.home()/'.cargo/bin/tauri-driver'),'--port',str(p),'--native-port',str(np)], env=env, stdout=log, stderr=log)
base = f'http://127.0.0.1:{p}'
def call(endpoint, payload=None, method=None):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(base+endpoint, data=data, method=method, headers={'Content-Type':'application/json'})
    with urllib.request.urlopen(req,timeout=30) as response:
        result=json.load(response)
    if isinstance(result.get('value'), dict) and 'error' in result['value']:
        raise RuntimeError(result['value'])
    return result['value']
session = None
try:
    for _ in range(100):
        try: call('/status'); break
        except Exception: time.sleep(.1)
    for slug, mode, name in [('nord','dark','Nord'), ('catppuccin-mocha','dark','Catppuccin Mocha'), ('flexoki-light','light','Flexoki Light')]:
        catalog_path=config/'dev.scrivo.editor/desktop-theme.json'
        catalog=json.loads(catalog_path.read_text()); catalog['theme']='builtin:desktop:'+slug; catalog['mode']=mode
        catalog_path.write_text(json.dumps(catalog))
        session=call('/session', {'capabilities':{'alwaysMatch':{'tauri:options':{'application':str(repo/'src-tauri/target/debug/scrivo'),'args':[str(config/'document.md')]}}}})['sessionId']
        def js(script,args=None): return call(f'/session/{session}/execute/sync', {'script':script,'args':args or []})
        for _ in range(100):
            if js("return !!document.querySelector('.markdown-body h1')"): break
            time.sleep(.1)
        source=obsidian/name/'theme.css'
        comparison=js("""
            const frame=document.createElement('iframe'); frame.style.display='none'; document.body.append(frame);
            const d=frame.contentDocument; d.documentElement.className='theme-'+arguments[1]; d.body.className='theme-'+arguments[1]+' ctp-full-palette';
            const style=d.createElement('style'); style.textContent=arguments[0]; d.head.append(style);
            const properties=['background-primary','background-secondary','background-secondary-alt','text-normal','text-muted','text-faint','code-background','text-selection'];
            const actual=getComputedStyle(document.body), expected=frame.contentWindow.getComputedStyle(d.body);
            const rows=properties.map(p=>({property:p,actual:actual.getPropertyValue('--'+p).trim(),expected:expected.getPropertyValue('--'+p).trim()}));
            d.body.style.color='var(--text-normal)';
            const container=d.createElement('div'); container.className='markdown-rendered'; d.body.append(container);
            const checks=[['h1','h1','var(--h1-color, var(--text-normal))'],['strong','strong','var(--bold-color, inherit)'],['em','em','var(--italic-color, inherit)'],['a[href^="https:"]','a','var(--link-external-color, var(--link-color, var(--text-accent)))'],['a[href^="./"]','a','var(--link-color, var(--text-accent))']];
            for(const [selector,tag,value] of checks){const e=d.createElement(tag); e.style.color=value; container.append(e); const observed=document.querySelector('.markdown-body '+selector); rows.push({property:selector,actual:getComputedStyle(observed).color,expected:frame.contentWindow.getComputedStyle(e).color});}
            const values={h1:rows.find(r=>r.property==='h1').expected,strong:rows.find(r=>r.property==='strong').expected,em:rows.find(r=>r.property==='em').expected,external:rows.find(r=>r.property.startsWith('a[href^="https')).expected,internal:rows.find(r=>r.property.startsWith('a[href^="./')).expected};
            frame.remove(); return {rows,values};
        """,[source.read_text(),mode])
        assert all(row['actual']==row['expected'] for row in comparison['rows']), (slug,comparison)
        call(f'/session/{session}/actions',{'actions':[{'type':'key','id':'keyboard','actions':[{'type':'keyDown','value':'\ue009'},{'type':'keyDown','value':'e'},{'type':'keyUp','value':'e'},{'type':'keyUp','value':'\ue009'}]}]})
        for _ in range(100):
            if js("return !!document.querySelector('.cm-lp-strong')"): break
            time.sleep(.1)
        editing=js("""return {h1:getComputedStyle(document.querySelector('.cm-lp-h1')).color,strong:getComputedStyle(document.querySelector('.cm-lp-strong')).color,em:getComputedStyle(document.querySelector('.cm-lp-em')).color,external:getComputedStyle(document.querySelector('.cm-lp-link-external')).color,internal:getComputedStyle([...document.querySelectorAll('.cm-lp-link:not(.cm-lp-link-external)')].find(e=>e.textContent==='internal')).color}""")
        assert editing==comparison['values'],(slug,'editor',editing,comparison['values'])
        print(json.dumps({'result':'PASS Obsidian reading and editing colors','theme':slug,'mode':mode,'comparisons':len(comparison['rows'])+len(editing)}),flush=True)
        call(f'/session/{session}',method='DELETE');session=None
finally:
    if session:
        try: call(f'/session/{session}',method='DELETE')
        except Exception: pass
    driver.terminate()
    try: driver.wait(timeout=10)
    except subprocess.TimeoutExpired: driver.kill()
    log.close()
    workspace.cleanup()
