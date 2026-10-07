#!/usr/bin/env python3
"""Checks browser failures reproduced through live MCP tools."""

import json
import test_browser


class BrowserRegressionTests(test_browser.BrowserTests):
    """Checks caret edits, click barriers, and snapshot completeness in WebKit."""

    def test_typing_at_start_and_selected_range(self):
        """Inserts consecutive characters at the caret and replaces selected text."""
        page = self.open_page()['page']
        self.evaluate(page, "window.field=document.querySelector('#name');field.value='abc';field.focus();field.setSelectionRange(0,0)")
        self.call('act', page=page, action='type', target='#name', text='XYZ')
        self.assertEqual(self.evaluate(page, 'field.value'), 'XYZabc')
        self.evaluate(page, 'field.setSelectionRange(1,4)')
        self.call('act', page=page, action='type', target='#name', text='12')
        self.assertEqual(self.evaluate(page, 'field.value'), 'X12bc')

    def test_home_end_and_shift_selection(self):
        """Moves the caret to input boundaries and extends selection with Shift."""
        page = self.open_page()['page']
        self.evaluate(page, "window.field=document.querySelector('#name')")
        self.call('act', page=page, action='fill', target='#name', text='abc')
        self.call('act', page=page, action='press', target='#name', key='Home')
        self.assertEqual(self.evaluate(page, 'field.selectionStart'), 0)
        self.call('act', page=page, action='press', target='#name', key='Shift+End')
        self.assertEqual(self.evaluate(page, '[field.selectionStart,field.selectionEnd]'), [0, 3])
        self.call('act', page=page, action='type', target='#name', text='new')
        self.assertEqual(self.evaluate(page, 'field.value'), 'new')
        self.call('act', page=page, action='press', target='#name', key='Home')
        self.call('act', page=page, action='press', target='#name', key='End')
        self.assertEqual(self.evaluate(page, 'field.selectionStart'), 3)

    def test_hidden_and_covered_clicks_do_not_fire(self):
        """Rejects blocked controls without firing their click handlers."""
        page = self.open_page()['page']
        self.evaluate(page, """
          window.clicks = 0;
          apply.onclick = () => { window.clicks++; };
          apply.hidden = true;
        """)
        with self.assertRaisesRegex(RuntimeError, 'hidden'):
            self.call('act', page=page, action='click', target='#apply')
        self.evaluate(page, """
          apply.hidden = false;
          const box = apply.getBoundingClientRect();
          const cover = document.createElement('div');
          cover.id = 'cover';
          cover.style.cssText = `position:fixed;left:${box.left}px;top:${box.top}px;width:${box.width}px;height:${box.height}px;z-index:999`;
          document.body.append(cover);
        """)
        with self.assertRaisesRegex(RuntimeError, 'covered by div#cover'):
            self.call('act', page=page, action='click', target='#apply')
        self.assertEqual(self.evaluate(page, 'window.clicks'), 0)

    def test_snapshot_reports_text_and_depth_truncation(self):
        """Marks clipped paragraph text and omitted descendant nodes as truncated."""
        page = self.open_page()['page']
        self.evaluate(page, "bottom.textContent='BEGIN '+ 'word '.repeat(120)+'END_MARKER'")
        snapshot = self.call('snapshot', page=page, selector='#bottom')
        self.assertTrue(snapshot['truncated'])
        self.assertNotIn('END_MARKER', snapshot['snapshot'])
        self.assertIn('END_MARKER', self.call('get', page=page, what='text', target='#bottom')['text'])
        self.assertTrue(self.call('snapshot', page=page, max_depth=0)['truncated'])

    def test_readonly_fill_is_rejected(self):
        """Leaves read-only field contents unchanged after a rejected fill."""
        page = self.open_page()['page']
        self.evaluate(page, "window.field=document.querySelector('#name');field.value='original';field.readOnly=true")
        with self.assertRaisesRegex(RuntimeError, 'read-only'):
            self.call('act', page=page, action='fill', target='#name', text='changed')
        self.assertEqual(self.evaluate(page, 'field.value'), 'original')

    def test_download_attribute_queues_renderable_file(self):
        """Queues download links with renderable responses without navigating the page."""
        page = self.open_page(hidden=False)['page']
        self.evaluate(page, "next.setAttribute('download','fixture.html')")
        self.call('act', page=page, action='click', target='#next')
        self.assertEqual(self.call('get', page=page, what='url')['value'], self.url)
        queued = self.call('download', page=page, action='list')['downloads']
        self.assertEqual(queued[-1]['url'], self.url + 'next')
        self.assertEqual(queued[-1]['filename'], 'fixture.html')
        self.call('input', page=page, action='click', target='#next')
        queued = self.call('download', page=page, action='list')['downloads']
        self.assertEqual(len(queued), 2)
        self.assertEqual(self.call('get', page=page, what='url')['value'], self.url)

    def test_native_fill_immediately_after_open(self):
        """Inserts text into a newly shown native view without a rendering delay."""
        page = self.open_page(hidden=False)['page']
        self.call('input', page=page, action='fill', target='#name', text='Immediate')
        self.assertEqual(self.call('get', page=page, what='value', target='#name')['value'], 'Immediate')

    def test_inspection_annotations_exclude_actions_and_credentials(self):
        """Marks inspection tools read-only without approving actions or credential access."""
        type(self).request_id += 1
        self.bridge.stdin.write(json.dumps({
            'id': self.request_id, 'jsonrpc': '2.0', 'method': 'tools/list',
        }) + '\n')
        self.bridge.stdin.flush()
        tools = json.loads(self.bridge.stdout.readline())['result']['tools']
        by_name = {tool['name']: tool for tool in tools}
        for name in ['get', 'list', 'snapshot', 'screenshot', 'capabilities']:
            self.assertTrue(by_name[f'emacs_browser_{name}']['annotations']['readOnlyHint'])
        for name in ['act', 'eval', 'input', 'cookies', 'storage', 'wait']:
            self.assertNotIn('annotations', by_name[f'emacs_browser_{name}'])


if __name__ == '__main__':
    import unittest
    unittest.main(verbosity=2)
