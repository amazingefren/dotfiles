#!/usr/bin/env python3
"""Checks contenteditable, exact labels, URL metadata and configure discovery."""

import json
from urllib.parse import quote
import test_regressions


class ContenteditableTests(test_regressions.BrowserRegressionTests):
    """Exercises editing and tool discovery through the live MCP transport."""

    def open_editor_page(self):
        """Opens the reported data-URL fixture and tracks its page for cleanup."""
        html = '<label>Choice <select><option>Alpha</option><option>Beta</option></select></label><div id="editor" contenteditable="true">hello</div>'
        opened = self.call('open', hidden=True, url='data:text/html,' + quote(html))
        self.pages.append(opened['page'])
        return opened

    def test_contenteditable_home_end_and_selection(self):
        """Moves and extends an editor caret, then replaces the selected text."""
        page = self.open_editor_page()['page']
        self.call('act', page=page, action='press', target='#editor', key='Home')
        self.call('act', page=page, action='press', target='#editor', key='Shift+End')
        self.assertEqual(self.evaluate(page, 'getSelection().toString()'), 'hello')
        self.call('act', page=page, action='type', target='#editor', text='new')
        self.assertEqual(self.call('get', page=page, what='text', target='#editor')['text'], 'new')
        self.call('act', page=page, action='press', target='#editor', key='Home')
        self.call('act', page=page, action='type', target='#editor', text='start ')
        self.call('act', page=page, action='press', target='#editor', key='End')
        self.call('act', page=page, action='type', target='#editor', text=' end')
        self.assertEqual(self.call('get', page=page, what='text', target='#editor')['text'], 'start new end')

    def test_contenteditable_type_without_selection(self):
        """Appends typed text after clearing all selection ranges in a focused editor."""
        page = self.open_editor_page()['page']
        for _attempt in range(2):
            self.evaluate(page, 'editor.focus();getSelection().removeAllRanges()')
            self.call('act', page=page, action='type', target='#editor', text='!')
        self.assertEqual(self.call('get', page=page, what='text', target='#editor')['text'], 'hello!!')

    def test_contenteditable_keys_respect_line_boundaries(self):
        """Moves within the current line in an editor containing separate block elements."""
        page = self.open_editor_page()['page']
        self.evaluate(page, """
          editor.innerHTML = '<div>first</div><div>second</div>';
          editor.focus();
          getSelection().collapse(editor.lastChild.firstChild, 3);
        """)
        self.call('act', page=page, action='press', target='#editor', key='Home')
        self.call('act', page=page, action='press', target='#editor', key='Shift+End')
        self.assertEqual(self.evaluate(page, 'getSelection().toString()'), 'second')

    def test_contenteditable_outside_selection_preserves_other_text(self):
        """Types into the target editor without changing a selection outside it."""
        page = self.open_editor_page()['page']
        self.evaluate(page, """
          const paragraph = document.createElement('p');
          paragraph.id = 'other';
          paragraph.textContent = 'outside';
          document.body.append(paragraph);
          editor.focus();
          const range = document.createRange();
          range.selectNodeContents(paragraph);
          getSelection().removeAllRanges();
          getSelection().addRange(range);
        """)
        self.call('act', page=page, action='type', target='#editor', text='!')
        self.assertEqual(self.call('get', page=page, what='text', target='#editor')['text'], 'hello!')
        self.assertEqual(self.call('get', page=page, what='text', target='#other')['text'], 'outside')

    def test_exact_wrapped_select_label(self):
        """Resolves the select by its label without including option text."""
        page = self.open_editor_page()['page']
        locator = {'exact': True, 'label': 'Choice'}
        self.assertEqual(self.call('get', page=page, what='count', target=locator)['value'], 1)
        self.call('act', page=page, action='select', target=locator, values='Beta')
        self.assertEqual(self.call('get', page=page, what='value', target=locator)['value'], 'Beta')
        snapshot = self.call('snapshot', page=page)['snapshot']
        self.assertIn('combobox "Choice"', snapshot)
        self.assertNotIn('Choice Alpha Beta', snapshot)

    def test_exact_long_label_keeps_full_matching_text(self):
        """Matches complete label text while snapshots clip the displayed name."""
        page = self.open_editor_page()['page']
        label = 'Choice ' * 30 + 'end'
        self.evaluate(page, f'document.querySelector("label").firstChild.textContent={json.dumps(label)}')
        locator = {'exact': True, 'label': label}
        self.assertEqual(self.call('get', page=page, what='count', target=locator)['value'], 1)
        self.assertTrue(self.call('snapshot', page=page)['truncated'])

    def test_data_url_metadata_keeps_explicit_url_reads(self):
        """Shortens repeated metadata while retaining exact URLs in explicit reads."""
        opened = self.open_editor_page()
        page = opened['page']
        self.assertTrue(opened['url_truncated'])
        self.assertLessEqual(len(opened['url']), 161)
        full_url = self.call('get', page=page, what='url')['value']
        self.assertGreater(len(full_url), 160)
        self.assertEqual(full_url, self.evaluate(page, 'location.href'))
        acted = self.call('act', page=page, action='focus', target='#editor')
        self.assertTrue(acted['url_truncated'])
        snapshot = self.call('snapshot', page=page)
        self.assertTrue(snapshot['url_truncated'])
        listed = next(item for item in self.call('list')['pages'] if item['id'] == page)
        self.assertTrue(listed['url_truncated'])

    def test_configure_schema_and_missing_settings(self):
        """Exposes configure arguments directly and rejects calls without settings."""
        type(self).request_id += 1
        self.bridge.stdin.write(json.dumps({
            'id': self.request_id, 'jsonrpc': '2.0', 'method': 'tools/list',
        }) + '\n')
        self.bridge.stdin.flush()
        tools = json.loads(self.bridge.stdout.readline())['result']['tools']
        configure = next(tool for tool in tools if tool['name'] == 'emacs_browser_configure')
        schema = configure['inputSchema']
        self.assertEqual(set(schema['properties']), {'page', 'user_agent', 'viewport'})
        self.assertNotIn('anyOf', schema)
        page = self.open_editor_page()['page']
        with self.assertRaisesRegex(RuntimeError, 'configure needs user_agent or viewport'):
            self.call('configure', page=page)
        configured = self.call('configure', page=page, viewport={'height': 600, 'width': 800})
        self.assertEqual(configured['viewport'], {'height': 600, 'width': 800})
        self.call('configure', page=page, viewport=None)


if __name__ == '__main__':
    import unittest
    unittest.main(verbosity=2)
