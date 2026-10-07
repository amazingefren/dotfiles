#!/usr/bin/env python3
"""Tests the live browser MCP against a local HTTP fixture; requires patched Emacs."""

import base64
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class BrowserTests(unittest.TestCase):
    """Checks real browser state and HTTP headers through the stdio MCP bridge."""

    @classmethod
    def setUpClass(cls):
        """Starts the fixture HTTP server and MCP transport; raises on startup failure."""
        cls.headers = []
        cls.cookie_headers = []
        fixture = Path(__file__).with_name('fixture.html').read_bytes()

        class FixtureHandler(BaseHTTPRequestHandler):
            """Serves the fixture and records request paths and user-agent headers."""

            def do_GET(self):
                """Returns the fixture HTML and records its HTTP user agent."""
                cls.headers.append((self.path, self.headers.get('User-Agent')))
                cls.cookie_headers.append((self.path, self.headers.get('Cookie')))
                if self.path.startswith('/download'):
                    payload = b'native WebKit download\n'
                    self.send_response(200)
                    self.send_header('Content-Type', 'application/octet-stream')
                    self.send_header('Content-Disposition', 'attachment; filename=qa.txt')
                    self.send_header('Content-Length', str(len(payload)))
                    self.end_headers()
                    self.wfile.write(payload)
                    return
                self.send_response(200)
                self.send_header('Content-Type', 'text/html; charset=utf-8')
                self.send_header('Content-Length', str(len(fixture)))
                self.end_headers()
                self.wfile.write(fixture)

            def log_message(self, *_arguments):
                """Suppresses the optional HTTP access log."""

        cls.server = ThreadingHTTPServer(('127.0.0.1', 0), FixtureHandler)
        cls.server_thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.server_thread.start()
        cls.url = f'http://127.0.0.1:{cls.server.server_port}/'
        cls.root = Path(__file__).resolve().parents[6]
        cls.bridge = subprocess.Popen(
            [str(Path(__file__).resolve().parents[3] / 'bin/emacs-mcp')],
            env={**os.environ, 'EMACS_MCP_WORKSPACE_ROOT': str(cls.root),
                 'EMACS_SERVER_NAME': os.environ.get('EMACS_SERVER_NAME', 'webkit-qa')},
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
        )
        cls.request_id = 0

    @classmethod
    def tearDownClass(cls):
        """Stops the test transport and HTTP server without closing other browser pages."""
        cls.bridge.stdin.close()
        cls.bridge.wait(timeout=5)
        cls.bridge.stdout.close()
        cls.server.shutdown()
        cls.server.server_close()
        cls.server_thread.join(timeout=5)

    def setUp(self):
        """Tracks the pages created by this test."""
        self.pages = []

    def tearDown(self):
        """Closes every page created by this test."""
        for page in self.pages:
            self.call('close', page=page)

    def call(self, method, **arguments):
        """Calls a browser MCP method; raises RuntimeError for transport or tool failure."""
        type(self).request_id += 1
        self.bridge.stdin.write(json.dumps({
            'id': self.request_id, 'jsonrpc': '2.0', 'method': 'tools/call',
            'params': {'arguments': arguments, 'name': f'emacs_browser_{method}'},
        }) + '\n')
        self.bridge.stdin.flush()
        reply_line = self.bridge.stdout.readline()
        if not reply_line:
            raise RuntimeError(f'MCP transport exited during browser_{method}')
        result = json.loads(reply_line)['result']
        if result.get('isError'):
            raise RuntimeError(result['content'][0]['text'])
        content = result['content']
        if content[0]['type'] == 'image':
            return base64.b64decode(content[0]['data'])
        return json.loads(content[0]['text'])

    def evaluate(self, page, script):
        """Returns the JavaScript result from PAGE; raises for script failure."""
        return self.call('eval', page=page, script=script)['value']

    def open_page(self, hidden=True, **settings):
        """Opens the local fixture and tracks its page for cleanup."""
        opened = self.call('open', hidden=hidden, url=self.url, **settings)
        self.pages.append(opened['page'])
        return opened

    def test_capabilities(self):
        """Requires all native QA controls and reports synthetic input honestly."""
        capabilities = self.call('capabilities')
        for capability in ['native_screenshot', 'user_agent', 'viewport']:
            self.assertTrue(capabilities[capability], f'Missing patch: {capability}')
        self.assertFalse(capabilities['device_emulation'])

    def test_form_shadow_frame_and_upload(self):
        """Checks form actions, shadow DOM, same-origin frames, and real file content."""
        page = self.open_page()['page']
        self.call('snapshot', page=page, interactive=True)
        self.call('act', page=page, action='fill', target='#name', text='Café " \\')
        self.call('act', page=page, action='click', target='#apply')
        self.assertEqual(self.call('get', page=page, what='text', target='#output')['text'], 'Café " \\')
        self.call('act', page=page, action='check', target='#enabled')
        self.assertTrue(self.call('get', page=page, what='state', target='#enabled')['checked'])
        self.call('act', page=page, action='select', target='#choice', values='two')
        self.assertEqual(self.call('get', page=page, what='value', target='#choice')['value'], 'two')
        self.call('act', page=page, action='click', target='#shadow-button')
        self.assertEqual(self.call('get', page=page, what='text', target='#shadow-button')['text'], 'Clicked')
        self.call('act', page=page, action='fill', target='#child', text='Child value')
        self.assertEqual(self.call('get', page=page, what='value', target='#child')['value'], 'Child value')
        with tempfile.NamedTemporaryFile(dir=self.root, suffix='.txt') as upload:
            upload.write('Uploaded café'.encode())
            upload.flush()
            self.call('act', page=page, action='upload', target='#upload', files=[upload.name])
            self.call('wait', page=page, text='Uploaded café')
        self.assertEqual(self.call('get', page=page, what='text', target='#output')['text'], 'Uploaded café')

    def test_garbage_collection_during_callbacks(self):
        """Checks asynchronous page callbacks while Emacs collects garbage repeatedly."""
        page = self.open_page()['page']
        expression = '(run-at-time 0.01 nil (lambda () (garbage-collect)))'
        command = [os.environ.get('EMACSCLIENT', 'emacsclient'), '-s', os.environ.get('EMACS_SERVER_NAME', 'webkit-qa'), '--eval']
        try:
            for index in range(10):
                subprocess.run(command + [f'(setq webkit-qa-gc-timer {expression})'], check=True, capture_output=True)
                self.assertEqual(self.evaluate(page, f'new Promise(resolve => setTimeout(() => resolve({index}), 30))'), index)
        finally:
            subprocess.run(command + ['(cancel-timer webkit-qa-gc-timer)'], check=True, capture_output=True)

    def test_invalid_settings_leave_page_unchanged(self):
        """Rejects invalid geometry and user agents before mutating the page."""
        opened = self.open_page(user_agent='QA/1', viewport={'height': 844, 'width': 390})
        page = opened['page']
        with self.assertRaisesRegex(RuntimeError, 'viewport'):
            self.call('configure', page=page, user_agent='Changed/1', viewport={'height': 720, 'width': 0})
        self.assertEqual(self.evaluate(page, 'navigator.userAgent'), 'QA/1')
        with self.assertRaisesRegex(RuntimeError, 'user_agent'):
            self.call('configure', page=page, user_agent='Bad\r\nHeader')
        self.assertEqual(self.evaluate(page, 'window.innerWidth'), 390)

    def test_native_cookies_and_profile_isolation(self):
        """Checks HttpOnly cookies, profile sharing, isolation and targeted deletion."""
        profile = {'name': 'qa-cookies'}
        first = self.open_page(profile=profile)['page']
        self.call('session', page=first, action='clear')
        shared = self.open_page(profile=profile)['page']
        isolated = self.open_page(profile={'name': 'qa-isolated'})['page']
        cookie = {'domain': '127.0.0.1', 'http_only': True, 'name': 'qa_auth',
                  'path': '/', 'same_site': 'lax', 'value': 'secret'}
        self.call('cookies', page=first, action='set', cookies=[cookie])
        stored = self.call('cookies', page=shared, action='get', name='qa_auth')['cookies']
        self.assertEqual(len(stored), 1)
        self.assertTrue(stored[0]['http_only'])
        self.assertEqual(stored[0]['value'], 'secret')
        self.assertNotIn('qa_auth=', self.evaluate(first, 'document.cookie'))
        self.assertEqual(self.call('cookies', page=isolated, action='get')['cookies'], [])
        session = self.call('session', page=first, action='info')
        self.assertFalse(session['persistent'])
        self.assertEqual(session['profile'], 'qa-cookies')
        self.assertEqual(self.call('cookies', page=first, action='clear', name='qa_auth')['deleted'], 1)
        self.assertEqual(self.call('cookies', page=shared, action='get')['cookies'], [])

    def test_storage_state_and_profile_clear(self):
        """Round-trips cookies and origin storage; rejects mismatched origins and clears profile data."""
        page = self.open_page(profile={'name': 'qa-storage'})['page']
        self.evaluate(page, "localStorage.setItem('local', '漢字'); sessionStorage.setItem('session', 'ok')")
        self.call('cookies', page=page, action='set', cookies=[
            {'domain': '127.0.0.1', 'name': 'qa_state', 'path': '/', 'value': 'saved'}])
        state = self.call('storage', page=page, action='export')['state']
        self.assertEqual(state['local_storage'], {'local': '漢字'})
        self.assertEqual(state['session_storage'], {'session': 'ok'})
        wrong_origin = {**state, 'origin': 'https://example.invalid'}
        with self.assertRaisesRegex(RuntimeError, 'does not match'):
            self.call('storage', page=page, action='import', state=wrong_origin)
        self.call('storage', page=page, action='clear')
        self.assertEqual(self.evaluate(page, 'localStorage.length + sessionStorage.length'), 0)
        self.call('storage', page=page, action='import', state=state)
        self.assertEqual(self.evaluate(page, "localStorage.getItem('local')"), '漢字')
        self.call('session', page=page, action='clear')
        self.call('navigate', page=page, action='reload')
        self.assertEqual(self.call('cookies', page=page, action='get')['cookies'], [])
        self.assertEqual(self.evaluate(page, 'localStorage.length'), 0)

    def test_persistent_profile_and_invalid_cookie_batch(self):
        """Checks persistent profile selection and cookie validation before any writes."""
        page = self.open_page(profile={'name': 'qa-persistent', 'persistent': True})['page']
        self.assertTrue(self.call('session', page=page, action='info')['persistent'])
        self.call('session', page=page, action='clear')
        with self.assertRaisesRegex(RuntimeError, 'Invalid cookie'):
            self.call('cookies', page=page, action='set', cookies=[
                {'domain': '127.0.0.1', 'name': 'valid', 'path': '/', 'value': 'ok'},
                {'domain': '127.0.0.1', 'name': 'invalid', 'path': 'bad', 'value': 'bad'}])
        self.assertEqual(self.call('cookies', page=page, action='get')['cookies'], [])

    def test_native_input_and_editor_selection(self):
        """Checks trusted native clicks and typing while preserving the selected Emacs window."""
        page = self.open_page(hidden=False, viewport={'width': 800, 'height': 600})['page']
        command = [os.environ.get('EMACSCLIENT', 'emacsclient'), '-s',
                   os.environ.get('EMACS_SERVER_NAME', 'webkit-qa'), '--eval']
        subprocess.run(command + ['(setq webkit-qa-selected-window (selected-window))'],
                       check=True, capture_output=True)
        self.evaluate(page, "window.qaEvents=[]; for (const name of ['click','input','keydown']) document.addEventListener(name,e=>qaEvents.push({type:e.type,trusted:e.isTrusted}))")
        self.call('input', page=page, action='click', target='#name')
        self.call('input', page=page, action='type', text='Native')
        self.call('input', page=page, action='fill', text='Replaced')
        self.call('wait', page=page, function="()=>document.querySelector('#name').value==='Replaced'", timeout_ms=5_000)
        self.call('input', page=page, action='click', target='#apply')
        self.call('wait', page=page, function="()=>document.querySelector('#output').textContent==='Replaced'", timeout_ms=5_000)
        events = self.evaluate(page, 'qaEvents')
        self.assertTrue(any(event['type'] == 'input' for event in events))
        self.assertTrue(all(event['trusted'] for event in events))
        selected = subprocess.run(command + ['(eq webkit-qa-selected-window (selected-window))'],
                                  check=True, capture_output=True, text=True)
        self.assertEqual(selected.stdout.strip(), 't')
        self.assertTrue(self.call('session', page=page, action='info')['editor_focused'])

    def test_native_download_and_dialog_policy(self):
        """Checks downloaded bytes, destination protection and configurable confirm/prompt responses."""
        page = self.open_page(profile={'name': 'qa-download'})['page']
        self.call('cookies', page=page, action='set', cookies=[
            {'domain': '127.0.0.1', 'http_only': True, 'name': 'qa_download_auth',
             'path': '/', 'value': 'present'}])
        with tempfile.TemporaryDirectory(prefix='webkit-download-') as directory:
            path = Path(directory) / 'qa.txt'
            self.call('download', page=page, action='start', url=self.url + 'download', path=str(path))
            self.assertEqual(path.read_bytes(), b'native WebKit download\n')
            self.assertTrue(any(path.startswith('/download') and 'qa_download_auth=present' in (cookies or '')
                                for path, cookies in self.cookie_headers))
            with self.assertRaisesRegex(RuntimeError, 'destination exists'):
                self.call('download', page=page, action='start', url=self.url + 'download', path=str(path))
        self.call('dialogs', page=page, confirm=False, prompt=None)
        self.assertEqual(self.evaluate(page, "({confirmed:confirm('qa'),prompted:prompt('qa','default')})"),
                         {'confirmed': False, 'prompted': None})
        self.evaluate(page, f"document.body.insertAdjacentHTML('beforeend', '<a id=qa-download href={self.url}download?link>Download</a>')")
        self.call('act', page=page, action='click', target='#qa-download')
        command = [os.environ.get('EMACSCLIENT', 'emacsclient'), '-s',
                   os.environ.get('EMACS_SERVER_NAME', 'webkit-qa'), '--eval']
        subprocess.run(command + ['(sit-for 0.5)'], check=True, capture_output=True)
        downloads = self.call('download', page=page, action='list')['downloads']
        self.assertTrue(any(download['url'].endswith('/download?link') for download in downloads))

    def test_navigation_console_and_waits(self):
        """Checks navigation, console messages, true/false waits, and detached refs."""
        page = self.open_page()['page']
        snapshot = self.call('snapshot', page=page, interactive=True)['snapshot']
        ref = re.search(r'button "Apply" \[ref=(e\d+)\]', snapshot).group(1)
        self.evaluate(page, "document.querySelector('#apply').remove(); true")
        self.call('wait', page=page, target=ref, state='detached', timeout_ms=100)
        with self.assertRaisesRegex(RuntimeError, 'Timed out'):
            self.call('wait', page=page, function='() => false', timeout_ms=100)
        self.call('wait', page=page, function='() => true', timeout_ms=100)
        self.evaluate(page, "console.log('QA console'); true")
        self.assertTrue(any(entry['text'] == 'QA console' for entry in self.call('console', page=page)['entries']))
        self.call('act', page=page, action='click', target='#next')
        self.call('wait', page=page, url_contains='/next')
        self.call('navigate', page=page, action='back')
        self.assertEqual(self.call('get', page=page, what='url')['value'], self.url)
        self.call('navigate', page=page, action='forward')
        self.assertTrue(self.call('get', page=page, what='url')['value'].endswith('/next'))
        self.call('navigate', page=page, action='reload')

    def test_screenshot_dimensions_and_hidden_state(self):
        """Captures exact CSS-pixel PNGs from hidden pages at phone and desktop sizes."""
        page = self.open_page()['page']
        for width, height in [(390, 844), (1920, 1080)]:
            self.call('configure', page=page, viewport={'height': height, 'width': width})
            screenshot = self.call('screenshot', page=page)
            self.assertEqual(screenshot[:8], b'\x89PNG\r\n\x1a\n')
            self.assertEqual(struct.unpack('>II', screenshot[16:24]), (width, height))
            self.evaluate(page, "document.body.style.background = 'Highlight'; true")
            changed = self.call('screenshot', page=page)
            self.assertNotEqual(screenshot, changed)
            self.evaluate(page, "document.body.style.background = 'Canvas'; true")
        summary = next(summary for summary in self.call('list')['pages'] if summary['id'] == page)
        self.assertFalse(summary['shown'])

    def test_user_agent_first_request_reset_and_isolation(self):
        """Verifies first-request headers, navigator overrides, reset, and page isolation."""
        default = self.open_page()
        native_default = self.open_page(user_agent=None)
        mobile = self.open_page(user_agent='QA Mobile/1', viewport={'height': 844, 'width': 390})
        self.assertEqual(mobile['user_agent'], 'QA Mobile/1')
        self.assertEqual(self.headers[-1][1], 'QA Mobile/1')
        self.assertEqual(self.evaluate(default['page'], 'navigator.userAgent'), default['user_agent'])
        reset = self.call('configure', page=mobile['page'], user_agent=None)
        self.assertEqual(reset['user_agent'], native_default['user_agent'])
        self.assertEqual(self.headers[-1][1], native_default['user_agent'])

    def test_viewport_breakpoints_and_window_resize(self):
        """Preserves a fixed CSS viewport through pane resize and restores native sizing."""
        opened = self.open_page(hidden=False, viewport={'height': 1080, 'width': 1920})
        page = opened['page']
        self.assertEqual(opened['viewport'], {'height': 1080, 'width': 1920})
        self.assertEqual(self.evaluate(page, "getComputedStyle(document.querySelector('#layout'),'::after').content"), '"wide"')
        phone = self.call('configure', page=page, viewport={'height': 844, 'width': 390})
        self.assertEqual(phone['viewport'], {'height': 844, 'width': 390})
        self.assertEqual(self.evaluate(page, "getComputedStyle(document.querySelector('#layout'),'::after').content"), '"narrow"')
        command = [os.environ.get('EMACSCLIENT', 'emacsclient'), '-s', os.environ.get('EMACS_SERVER_NAME', 'webkit-qa'), '--eval']
        expression = f'(let ((page (webkit-agent-find-page "{page}"))) (xwidget-resize (webkit-agent--xwidget page) 320 240))'
        subprocess.run(command + [expression], check=True, capture_output=True)
        self.assertEqual(self.evaluate(page, '({height:innerHeight,width:innerWidth})'), {'height': 844, 'width': 390})
        restored = self.call('configure', page=page, viewport=None)
        self.assertEqual(restored['viewport'], {'height': 240, 'width': 320})


if __name__ == '__main__':
    unittest.main(verbosity=2)
