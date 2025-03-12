return { 'L3MON4D3/LuaSnip',
  opts = function ()
    local ls = require'luasnip'
    local s = ls.snippet
    local sn = ls.snippet_node
    local t = ls.text_node
    local i = ls.insert_node
    local f = ls.function_node
    local c = ls.choice_node
    local d = ls.dynamic_node
    local r = ls.restore_node
    local fmt = require("luasnip.extras.fmt").fmt

    local sep = "-----------------------------------------------------"

    ls.config.set_config({
      history = false
    })


    ls.add_snippets("all", {
      ls.parser.parse_snippet({trig="phpd"}, [[
    // Debugging: \$$1
    file_put_contents('/var/www/html/tmp/debug.json', PHP_EOL.str_repeat('-', 30).PHP_EOL.'$1'.PHP_EOL.str_repeat('-', 30).PHP_EOL.json_encode(\$$1, JSON_PRETTY_PRINT).PHP_EOL, FILE_APPEND | LOCK_EX );
        ]]
      )
    })

    return {}
  end
}
