"""JavaScript dialog checks inside the existing, VM-owned web AppFixture."""
import json
import time
from api_fixture import ROOT, eventually


def check_browser_dialogs(app, browser_pane, plugin_pane, base_url, plugin_id="web.fixture"):
    """Call after chooser checks, before verify-web replaces or closes plugin_pane."""
    captures = ROOT / "artifacts/web-dialogs"
    captures.mkdir(exist_ok=True)
    evidence = []

    def evaluate(pane, script):
        method = "debug.pluginEval" if pane == plugin_pane else "browser.eval"
        return app.rpc(method, pane=pane, script=script)

    def activate(pane):
        tab = app.rpc("pane.inspect", pane=pane)["tabId"]
        app.rpc("debug.activate", tab=tab)
        eventually("active dialog fixture", lambda: app.rpc("debug.inspect")["applicationActive"])
        return tab

    def schedule(pane, kind, message="Dialog fixture", default="default response"):
        expression = {
            "alert": f"alert({json.dumps(message)})",
            "confirm": f"confirm({json.dumps(message)})",
            "prompt": f"prompt({json.dumps(message)},{json.dumps(default)})",
        }[kind]
        # The evaluation returns before WebKit pauses the page for its native dialog.
        evaluate(pane, """(() => {
            window.__slateDialogFixture = {done:false,count:0,value:null};
            setTimeout(() => {
                const value = %s;
                const result = window.__slateDialogFixture;
                result.value = value === undefined ? 'alert-finished' : value;
                result.count += 1;
                result.done = true;
            }, 50);
            return true;
        })()""" % expression)

    def opened(pane, kind, message="Dialog fixture", default="default response"):
        schedule(pane, kind, message, default)
        eventually("pending native JavaScript " + kind,
                   lambda: app.rpc("web.dialog", pane=pane)["dialog"] is not None)
        dialog = app.rpc("web.dialog", pane=pane)["dialog"]
        assert dialog["kind"] == kind and dialog["message"] == message, dialog
        assert dialog["origin"] and not dialog["truncated"], dialog
        if kind == "prompt":
            assert dialog["defaultText"] == default, dialog
        evidence.append(dict(pane=pane, dialog=dialog))
        return dialog

    def completed(pane, value):
        eventually("dialog callback resumes once",
                   lambda: evaluate(pane, "window.__slateDialogFixture.done"))
        result = evaluate(pane, "window.__slateDialogFixture")
        assert result == dict(done=True, count=1, value=value), result
        assert app.rpc("web.dialog", pane=pane)["dialog"] is None

    def respond(pane, dialog, action, **params):
        result = app.rpc("web.respondDialog", pane=pane, dialogId=dialog["dialogId"], action=action, **params)
        assert result["accepted"] == (action == "accept"), result
        return result

    for pane in [browser_pane, plugin_pane]:
        tab = activate(pane)
        assert app.rpc("web.dialog", pane=pane)["dialog"] is None
        alert = opened(pane, "alert")
        if pane == browser_pane:
            assert alert["origin"] == base_url, alert
        assert app.cli("web", "dialog", "--pane", pane)["dialog"]["dialogId"] == alert["dialogId"]
        app.rpc("web.respondDialog", pane=pane, dialogId="stale", action="accept", error=-32050)
        app.rpc("web.respondDialog", pane=pane, dialogId=alert["dialogId"], action="accept",
                text="invalid for alert", error=-32602)
        app.rpc("web.respondDialog", pane=pane, dialogId=alert["dialogId"], action="accept",
                expectedViewId="stale", expectedDocumentId="stale", error=-32050)
        assert app.rpc("web.dialog", pane=pane)["dialog"]["dialogId"] == alert["dialogId"]
        respond(pane, alert, "accept")
        completed(pane, "alert-finished")

        confirm = opened(pane, "confirm")
        # Replaying an earlier token must not consume the current dialog.
        app.rpc("web.respondDialog", pane=pane, dialogId=alert["dialogId"], action="accept", error=-32050)
        assert app.rpc("web.dialog", pane=pane)["dialog"]["dialogId"] == confirm["dialogId"]
        result = app.cli("web", "respond-dialog", "--pane", pane, "--dialog-id", confirm["dialogId"],
                         "--response", "dismiss")
        assert result["accepted"] is False
        completed(pane, False)

        prompt = opened(pane, "prompt")
        respond(pane, prompt, "accept", text="")
        completed(pane, "")
        prompt = opened(pane, "prompt")
        respond(pane, prompt, "dismiss")
        completed(pane, None)
        prompt = opened(pane, "prompt")
        respond(pane, prompt, "accept")
        completed(pane, "default response")

        # These press NSAlert's real controls, not the trusted response operation.
        for kind, action, expected in [
            ("alert", "accept", "alert-finished"),
            ("confirm", "accept", True),
            ("confirm", "dismiss", False),
            ("prompt", "accept", "native response"),
            ("prompt", "dismiss", None),
        ]:
            dialog = opened(pane, kind, f"Native {kind}: {action}")
            path = captures / f"{pane}-{kind}-{action}.png"
            time.sleep(0.35)
            app.rpc("debug.screenshot", tab=tab, sheet=True, path=str(path))
            assert path.read_bytes().startswith(b"\x89PNG\r\n\x1a\n")
            native = dict(pane=pane, action=action)
            if kind == "prompt":
                native["text"] = "native response"
            app.rpc("debug.webDialog", **native)
            completed(pane, expected)
            app.rpc("web.respondDialog", pane=pane, dialogId=dialog["dialogId"], action="accept", error=-32050)

    # A registered plugin controls a browser dialog through its production bridge.
    dialog = opened(browser_pane, "confirm", "Plugin bridge confirmation")
    payload = dict(pane=browser_pane, dialogId=dialog["dialogId"], action="accept")
    bridge = evaluate(plugin_pane, "workspace.web.respondDialog(" + json.dumps(payload) + ")")
    assert bridge["accepted"] is True
    completed(browser_pane, True)

    # A sheet in the same workspace window denies a second confirm instead of accepting it.
    dialog = opened(browser_pane, "confirm", "Existing window sheet")
    schedule(plugin_pane, "confirm", "Conflicting window sheet")
    completed(plugin_pane, False)
    assert app.rpc("web.dialog", pane=browser_pane)["dialog"]["dialogId"] == dialog["dialogId"]
    respond(browser_pane, dialog, "dismiss")
    completed(browser_pane, False)

    # Navigation and plugin restart retire callbacks and tokens.
    old = opened(browser_pane, "prompt")
    app.rpc("browser.navigate", pane=browser_pane, url=base_url + "/index.html")
    assert app.rpc("web.dialog", pane=browser_pane)["dialog"] is None
    current = opened(browser_pane, "confirm")
    app.rpc("web.respondDialog", pane=browser_pane, dialogId=old["dialogId"], action="accept", error=-32050)
    respond(browser_pane, current, "dismiss")
    completed(browser_pane, False)

    old = opened(plugin_pane, "prompt")
    app.rpc("plugins.restart", id=plugin_id)
    eventually("plugin ready after dialog cancellation", lambda: app.rpc("pane.inspect", pane=plugin_pane)["webReady"])
    assert app.rpc("web.dialog", pane=plugin_pane)["dialog"] is None
    current = opened(plugin_pane, "confirm")
    app.rpc("web.respondDialog", pane=plugin_pane, dialogId=old["dialogId"], action="accept", error=-32050)
    respond(plugin_pane, current, "dismiss")
    completed(plugin_pane, False)

    # Closing an owned private tab must not leave its callback attached to the survivor.
    source_tab = app.rpc("pane.inspect", pane=browser_pane)["tabId"]
    private_tab = app.rpc("command.run", id="tab.new", focus="new")["tabId"]
    private_pane = app.rpc("context.inspect")["focusedPaneId"]
    try:
        app.rpc("command.run", id="pane.type", pane=private_pane, type="private-browser", force=True)
        app.rpc("browser.navigate", pane=private_pane, url=base_url + "/index.html")
        old = opened(private_pane, "prompt", "Closed private tab")
        app.rpc("command.run", id="tab.close", tab=private_tab, force=True)
        private_tab = None
        app.rpc("command.run", id="tab.focus", tab=source_tab)
        current = opened(browser_pane, "confirm")
        app.rpc("web.respondDialog", pane=browser_pane, dialogId=old["dialogId"], action="accept", error=-32050)
        respond(browser_pane, current, "dismiss")
        completed(browser_pane, False)
    finally:
        if private_tab is not None:
            app.rpc("command.run", id="tab.close", tab=private_tab, force=True)
        app.rpc("command.run", id="tab.focus", tab=source_tab)

    (captures / "dialogs.json").write_text(json.dumps(evidence, indent=2))
    print("PASS JavaScript dialogs: browser/plugin/private, socket/CLI/bridge, actual native controls, "
          "empty/cancel/default prompt, stale IDs, conflicting sheets, navigation/restart/close", flush=True)
