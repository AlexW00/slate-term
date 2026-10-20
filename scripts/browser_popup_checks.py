"""Controlled popup/login checks shared by the owned web integration fixture."""
import json
import time

from api_fixture import ROOT, eventually


PARENT = """<!doctype html><meta name="color-scheme" content="light dark">
<title>Popup opener fixture</title>
<style>body{font:18px system-ui;margin:32px}button{font:inherit;padding:10px}</style>
<h1>Local login fixture</h1><p>The opener must stay on this page.</p>
<button id="open" onclick="window.lastChild=window.open('popup-login.html','_blank','width=640,height=480')">Open login</button>
<p id="result">Waiting for login</p>
<script>
window.messages=[];
addEventListener('message',event=>{
  if(event.origin===location.origin&&event.data.kind==='fixture-login'){
    messages.push(event.data);
    document.getElementById('result').textContent='Logged in: '+event.data.session;
  }
});
window.automaticBlocked=null;
setTimeout(()=>{window.automaticBlocked=window.open('popup-login.html')===null},100);
</script>"""

CHILD = """<!doctype html><meta name="color-scheme" content="light dark">
<title>Popup login fixture</title>
<style>body{font:18px system-ui;margin:32px}button{font:inherit;padding:10px;margin:4px}</style>
<h1>Local login</h1><p>This is a controlled fixture with no account or credentials.</p>
<button id="finish" onclick="opener.postMessage({kind:'fixture-login',session:localStorage.getItem('popup-session')},location.origin);window.close()">Finish login</button>
<button id="nested" onclick="window.lastChild=window.open('popup-login.html','_blank','width=560,height=420')">Open nested window</button>
<button id="close" onclick="window.close()">Close window</button>"""


def run_popup_checks(app, assets, base, controller_pane=None, external_input=False):
    """Use an AppFixture and its running static HTTP server; owns temporary tabs."""
    (assets / 'popup-parent.html').write_text(PARENT)
    (assets / 'popup-login.html').write_text(CHILD)
    owned_tabs = []
    original_tab = app.rpc('pane.inspect', pane='p1')['tabId']

    def evaluate(pane, script, popup=None):
        target = dict(pane=pane)
        if popup is not None:
            target['popupId'] = popup
        return app.rpc('browser.eval', script=script, **target)

    def listing(pane):
        return app.rpc('browser.popups', pane=pane)

    def click(pane, selector, popup=None):
        target = dict(pane=pane)
        if popup is not None:
            target['popupId'] = popup
        point = evaluate(pane, """(()=>{
          const element=document.querySelector(%s);
          element.scrollIntoView({block:'center'});
          const r=element.getBoundingClientRect();
          return {x:r.x+r.width/2,y:r.y+r.height/2};
        })()""" % json.dumps(selector), popup)
        app.rpc('debug.browserClick', **target, **point)

    def open_child(pane, opener=None):
        before = {entry['popupId'] for entry in listing(pane)}
        click(pane, '#open' if opener is None else '#nested', opener)
        eventually('native click opens a child browser window',
                   lambda: len(listing(pane)) == len(before) + 1)
        row = next(entry for entry in listing(pane) if entry['popupId'] not in before)
        pid = row['popupId']
        eventually('child document ready',
                   lambda: app.rpc('web.get', pane=pane, popupId=pid)['ready'])
        assert row['openerPopupId'] == opener, row
        assert row['openerOrigin'] == base, row
        return pid

    def create_root(mode):
        tab = app.rpc('command.run', id='tab.new', focus='new')['tabId']
        owned_tabs.append(tab)
        pane = app.rpc('context.inspect')['focusedPaneId']
        app.rpc('command.run', id='pane.type', pane=pane, type=mode, force=True)
        app.rpc('browser.navigate', pane=pane, url=base + '/popup-parent.html')
        eventually('automatic popup attempt completes',
                   lambda: evaluate(pane, 'window.automaticBlocked') is not None)
        assert evaluate(pane, 'window.automaticBlocked') is True
        assert listing(pane) == [], 'An unrequested timer popup was admitted'
        return tab, pane

    def assert_retired(pane, pid):
        app.rpc('browser.get', pane=pane, popupId=pid, error=-32050)
        app.rpc('web.get', pane=pane, popupId=pid, error=-32050)
        app.rpc('browser.closePopup', pane=pane, popupId=pid, error=-32050)
        app.rpc('browser.eval', pane=pane, popupId=pid,
                script='document.title="MISROUTED"', error=-32050)
        assert evaluate(pane, 'document.title') == 'Popup opener fixture'

    try:
        _, normal = create_root('browser')
        evaluate(normal, "localStorage.setItem('popup-session','normal');document.cookie='popupSession=normal;path=/';true")
        opener = app.rpc('web.get', pane=normal)
        child = open_child(normal)
        assert evaluate(normal, 'location.href') == base + '/popup-parent.html'
        assert evaluate(normal, 'window.opener===null') is True
        assert evaluate(normal, 'window.opener!==null', child) is True
        assert evaluate(normal, 'typeof window.workspace', child) == 'undefined'
        assert evaluate(normal, "localStorage.getItem('popup-session')", child) == 'normal'
        assert 'popupSession=normal' in evaluate(normal, 'document.cookie', child)
        evaluate(normal, "document.cookie='fromPopup=shared;path=/';true", child)
        assert 'fromPopup=shared' in evaluate(normal, 'document.cookie')
        child_info = app.rpc('web.get', pane=normal, popupId=child)
        assert child_info['viewId'] != opener['viewId'] and child_info['popupId'] == child
        assert app.cli('browser', 'popups', '--pane', normal) == listing(normal)
        assert app.cli('web', 'get', '--pane', normal, '--popup-id', child)['viewId'] == child_info['viewId']
        app.rpc('browser.closePopup', pane=normal, popupId=child,
                expectedViewId=opener['viewId'], expectedDocumentId=opener['documentId'], error=-32050)
        assert len(listing(normal)) == 1
        screenshot = ROOT / 'artifacts/browser-popup-content.png'
        app.rpc('web.screenshot', pane=normal, popupId=child, path=str(screenshot))
        assert screenshot.read_bytes().startswith(b'\x89PNG\r\n\x1a\n')
        window_capture = ROOT / 'artifacts/browser-popup-window.png'
        time.sleep(0.5)
        app.rpc('debug.screenshot', pane=normal, popupId=child, path=str(window_capture))
        assert window_capture.read_bytes().startswith(b'\x89PNG\r\n\x1a\n')
        if controller_pane is not None:
            trusted = app.rpc('debug.pluginEval', pane=controller_pane,
                              script='workspace.browser.popups(%s)' % json.dumps(dict(pane=normal)))
            assert trusted == listing(normal)
            trusted = app.rpc('debug.pluginEval', pane=controller_pane,
                              script='workspace.web.get(%s)' % json.dumps(dict(pane=normal, popupId=child)))
            assert trusted['viewId'] == child_info['viewId'] and trusted['popupId'] == child
        if external_input:
            print('POPUP_NATIVE_LOGIN_READY', flush=True)
            eventually('external popup login click', lambda: evaluate(normal, 'window.messages.length') == 1, timeout=180)
        else:
            click(normal, '#finish', child)
        eventually('popup login message reaches retained opener',
                   lambda: evaluate(normal, 'window.messages.length') == 1)
        eventually('script closes popup window', lambda: listing(normal) == [])
        assert evaluate(normal, 'window.messages[0].session') == 'normal'
        assert_retired(normal, child)

        # Browser shortcuts stay in the popup, including when its address field owns focus.
        child = open_child(normal)
        root_document = app.rpc('web.get', pane=normal)['documentId']
        old_child_document = app.rpc('web.get', pane=normal, popupId=child)['documentId']
        focus = app.rpc('debug.key', pane=normal, popupId=child, chord='cmd+l', dispatch=True)
        assert focus['browserFocus']['addressFocused'], focus
        evaluate(normal, 'document.title="Before popup refresh";true', child)
        app.rpc('debug.key', pane=normal, popupId=child, chord='cmd+r', dispatch=True)
        eventually('popup shortcut refreshes child document',
                   lambda: (state := app.rpc('web.get', pane=normal, popupId=child))['ready']
                   and state['documentId'] != old_child_document and state['title'] == 'Popup login fixture')
        app.rpc('browser.navigate', pane=normal, popupId=child, url=base + '/popup-login.html?history=next')
        app.rpc('debug.key', pane=normal, popupId=child, chord='cmd+[', dispatch=True)
        eventually('popup back shortcut',
                   lambda: (state := app.rpc('browser.get', pane=normal, popupId=child))['url'] == base + '/popup-login.html'
                   and state['ready'] and not state['loading'])
        app.rpc('debug.key', pane=normal, popupId=child, chord='cmd+]', dispatch=True)
        eventually('popup forward shortcut',
                   lambda: (state := app.rpc('browser.get', pane=normal, popupId=child))['url'] == base + '/popup-login.html?history=next'
                   and state['ready'] and not state['loading'])
        assert app.rpc('web.get', pane=normal)['documentId'] == root_document
        app.rpc('debug.key', pane=normal, popupId=child, chord='cmd+k', dispatch=True)
        eventually('popup opens global command picker', lambda: app.rpc('debug.commandPicker')['visible'])
        for query, command in [('Refresh Browser', 'browser.reload'), ('Close Pane', 'pane.close')]:
            picker = app.rpc('debug.commandPicker', query=query)
            assert not any(row['id'] == command and row['enabled'] for row in picker['results']), picker
        app.rpc('debug.commandPicker', dismiss=True)
        app.rpc('debug.key', pane=normal, popupId=child, chord='cmd+w', dispatch=True)
        eventually('popup close shortcut retires child', lambda: listing(normal) == [])
        assert app.rpc('web.get', pane=normal)['documentId'] == root_document
        assert_retired(normal, child)

        # A native close retires the same identity and closes its descendants.
        child = open_child(normal)
        grandchild = open_child(normal, child)
        app.rpc('debug.browserClick', pane=normal, popupId=child, closeButton=True)
        eventually('native close cleans popup descendants', lambda: listing(normal) == [])
        assert_retired(normal, child)
        assert_retired(normal, grandchild)

        # Public guarded closure shares the native cleanup path.
        child = open_child(normal)
        grandchild = open_child(normal, child)
        current = app.rpc('web.get', pane=normal, popupId=child)
        result = app.cli('browser', 'close-popup', '--pane', normal, '--popup-id', child,
                         '--expected-view-id', current['viewId'], '--expected-document-id', current['documentId'])
        assert result == dict(popupId=child, closed=True)
        assert listing(normal) == []
        assert_retired(normal, grandchild)

        if controller_pane is not None:
            child = open_child(normal)
            closed = app.rpc('debug.pluginEval', pane=controller_pane,
                            script='workspace.browser.closePopup(%s)' % json.dumps(dict(pane=normal, popupId=child)))
            assert closed == dict(popupId=child, closed=True)
            assert_retired(normal, child)

        # Limit admission across the entire tree, with a separate native gesture each time.
        children = [open_child(normal) for _ in range(8)]
        click(normal, '#open')
        assert evaluate(normal, 'window.lastChild===null') is True
        assert len(listing(normal)) == 8
        for pid in children:
            app.rpc('browser.closePopup', pane=normal, popupId=pid)
        assert listing(normal) == []

        _, private = create_root('private-browser')
        assert evaluate(private, "localStorage.getItem('popup-session')") is None
        assert 'popupSession=normal' not in evaluate(private, 'document.cookie')
        evaluate(private, "localStorage.setItem('popup-session','private');document.cookie='popupSession=private;path=/';true")
        child = open_child(private)
        assert not next(row for row in listing(private) if row['popupId'] == child)['persistent']
        assert evaluate(private, "localStorage.getItem('popup-session')", child) == 'private'
        assert 'popupSession=private' in evaluate(private, 'document.cookie', child)
        assert evaluate(normal, "localStorage.getItem('popup-session')") == 'normal'
        _, other_private = create_root('private-browser')
        assert evaluate(other_private, "localStorage.getItem('popup-session')") is None
        assert 'popupSession=private' not in evaluate(other_private, 'document.cookie')

        # A popup stays renderable while its root's native tab is inactive.
        child_state = app.rpc('web.get', pane=private, popupId=child)
        assert child_state['renderable'] and child_state['screenshotReady']
        assert 'Local login' in app.rpc('web.snapshot', pane=private, popupId=child)['text']
        grandchild = open_child(private, child)
        app.rpc('command.run', id='pane.type', pane=private, type='terminal', force=True)
        app.rpc('command.run', id='pane.type', pane=private, type='private-browser', force=True)
        app.rpc('browser.navigate', pane=private, url=base + '/popup-parent.html')
        assert listing(private) == []
        assert_retired(private, child)
        assert_retired(private, grandchild)
        print('PASS popup windows: native gestures, retained opener/postMessage, native/script/API closure, descendants, stale routing, eight-window limit, private session inheritance and isolation')
    finally:
        for tab in reversed(owned_tabs):
            app.rpc('command.run', id='tab.close', tab=tab, force=True)
        app.cli('tabs', 'focus', '--tab', original_tab)
