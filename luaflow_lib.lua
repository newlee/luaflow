local _M = {}


local cjson = require "cjson"
local parser = require "lua-parser.parser"


local insert = table.insert
local concat = table.concat
local format = string.format
local find   = string.find
local sub    = string.sub
local max    = math.max
local min    = math.min
local encode = cjson.encode
local GLOBAL = '_G'


local DEBUG
local node_color = {}
local link_added = {}
local colors = {"#0288d1", "#03a9f4", "#ffc107", "#ffa000"}


local function log(...)
    print("[" .. debug.getinfo(2, "n").name .. "]", ...)
end

function _M.set_verbose()
    DEBUG = true
end

function _M.create_ctx()
    return {
        roots = {},
        no_roots = {},
        call = {},
        scope = { GLOBAL },
        seen = {}
    }
end

local function index_str(t)
    local s
    if t[1].tag == "Index" then
        s = index_str(t[1])
    else
        s = t[1][1]
    end

    return s .. "." .. t[2][1]
end

local function process_set_enter(t, ctx)
    -- `Set{ {lhs+} {expr+} }                 -- lhs1, lhs2... = e1, e2...
    for i, v in ipairs(t[2]) do
        if v.tag == "Function" then
            local node = t[1][i]
            local tag = node.tag
            if tag == "Id" then
                v.name = node[1]
            elseif tag == "Index" then
                v.name = index_str(node)
            else
                error("Unexpected node type: " .. tag)
            end
        end
    end
end
local function process_block_enter(t, ctx)
    -- `Set{ {lhs+} {expr+} }                 -- lhs1, lhs2... = e1, e2...
    
    for i, v in ipairs(t) do

        if v.tag == "Invoke" then
            if v[1][1] == "self" then 
                local name = v[2][1]
                local scope = ctx.scope[#ctx.scope]
                local tmp1 = scope:match("([^.]+).([^.]+)")
                local tmp2 = scope:match("([^.]+).([^.]+)", 2)
                local f_name = concat({tmp1, tmp2, name}, ".")
                -- table.remove(tmp,#tmp)
                local l = ctx.call[scope]
                if l == nil then
                    l = {}
                    ctx.call[scope] = l
                end

                l[#l + 1] = f_name
            end
        end
    end
end

-- TODO properly decode function name
-- For code block:
--
--     a = {
--       __index = function () end
--     }
--
-- Current name is : `__index`, should be `a.__index`
local function process_pair_enter(t, ctx)
    if t[2].tag == "Function" then
        t[2].name = t[1][1]
    end
end

local function process_localrec_enter(t, ctx)
    -- `Localrec{ ident expr }                -- only used for 'local function'
    for _, v in ipairs(t[2]) do
        if v.tag == "Function" then
            v.name = t[1][1][1]
            --print(v.name)
        end
    end
end

local function process_function_enter(t, ctx)
    --assert(t.name, "No function name: " .. encode(t))
    if t.name then
        insert(ctx.scope, t.name)

        -- add new function to root list
        ctx.roots[t.name] = true
    else
        if DEBUG then
            print("skip unnamed function: ",
                  sub(ctx.source, max(t.pos - 9, 0),
                      min(t.pos + 20, ctx.source_len)))
        end
    end
end

local function process_function_leave(t, ctx)
    --print("Current scope: ", encode(ctx.scope))
    --print("Deleting scope: ", ctx.scope[#ctx.scope])
    if t.name then
        ctx.scope[#ctx.scope] = nil
    end
end

local function process_call_enter(t, ctx)
    local node = t[1]
    local name
    if node.tag == "Id" then
        name = t[1][1]
    elseif node.tag == "Index" then
        name = index_str(node)
    else
        error("Unexpected tag, t: " .. encode(t))
    end
    assert(type(name) == "string", "name is not string" .. encode(name))

    local scope = ctx.scope[#ctx.scope]
    local l = ctx.call[scope]
    if l == nil then
        l = {}
        ctx.call[scope] = l
    end

    l[#l + 1] = name

    -- not root, remove from root list
    --print(name, ctx.roots[name])
    insert(ctx.no_roots, name)
end

local function visit(t, conf, ctx)
    --print(t.tag)
    local handler = conf[t.tag]

    if handler and handler.enter then
        handler.enter(t, ctx)
    end

    for _, v in ipairs(t) do
        if type(v) == "table" then
            visit(v, conf, ctx)
        end
    end

    if handler and handler.leave then
        handler.leave(t, ctx)
    end
end

function _M.parse(ctx, s)
    local t, err = parser.parse(s, "luaflow")

    if not t and err then
        return error(err)
    end

    ctx.source = s
    ctx.source_len = #s

    return t
end

function _M.adjust_ctx(ctx)
    for _, v in ipairs(ctx.no_roots) do
        ctx.roots[v] = nil
    end
end

local function is_exclude(conf, func)
    if conf and conf.exclude and conf.exclude[func] then
        return true
    end

    return false
end

local function get_flow(ctx, t, func, indent, conf)
    if is_exclude(conf, func) then
        return false
    end

    if #t ~= 0 then
        insert(t, "\n")
    end
    for _ = 1, indent do
        insert(t, " ")
    end

    assert(type(func) == "string", "name is not string: " .. encode(func))

    insert(t, func)

    local seen = ctx.seen
    if seen[func] and seen[func] > 0 then
        insert(t, " (recursive: see " .. seen[func] .. ")")
        return true
    else
        seen[func] = 1
    end

    local callee = ctx.call[func]

    if not callee then
        return true
    end

    for _, v in ipairs(callee) do
        get_flow(ctx, t, v, indent + 4, conf)
        if seen[v] then
            seen[v] = seen[v] - 1
        end
    end

    return true
end

function _M.get_root_flow(ctx, conf)
    local t = {}

    if conf.main then
        get_flow(ctx, t, conf.main, 0, conf)
        return t
    end

    local i = 0
    for _, _ in pairs(ctx.roots) do
        i = i + 1
    end

    if i == 0 then
        local func = ctx.no_roots[1]
        ctx.roots[func] = true
    end

    for func, _ in pairs(ctx.roots) do
        get_flow(ctx, t, func, 0, conf)
        ctx.seen = {}
    end

    return t
end

function _M.print_root_flow(ctx, conf)
    local t = _M.get_root_flow(ctx, conf)
    print(concat(t))
end

local function dot_escape_name(s)
    if find(s, ".", 1, true) then
        return '"' .. s .. '"'
    end
    return s
end

local color_index = 0
local function get_color()
    local r =  colors[color_index % #colors + 1]
    color_index = color_index + 1
    return r
end

local function get_node_color(name)
    if node_color[name] then
        return node_color[name]
    end

    local c = get_color()
    node_color[name] = c
    return c
end

local function get_dot_flow(ctx, t, caller, conf)
    if not is_exclude(conf, caller) then
        local v = ctx.call[caller]
        for _, callee in ipairs(v) do
            if not is_exclude(conf, callee) then
                local key = format("%s -> %s", dot_escape_name(caller),
                           dot_escape_name(callee))
                if not link_added[key] then
                    local c1 = get_node_color(caller)
                    local c2 = get_node_color(callee)

                    local link = format('%s [color="%s"];\n', key, c1)
                    insert(t, link)
                    --insert(t, format('edge [color="%s"];\n', c1))

                    insert(t, format('%s [color="%s" shape="box" style="rounded,filled"];\n',
                                     dot_escape_name(caller), c1))
                    insert(t, format('%s [color="%s" shape="box" style="rounded,filled"];\n',
                                     dot_escape_name(callee), c2))
                    link_added[key] = true
                end
            end
        end
    end
end

local function get_roots(ctx, func, t)
    local call = ctx.call

    if not call[func] then
        return
    end

    for _, callee in ipairs(call[func]) do
        if not t[callee] then
            get_roots(ctx, callee, t)
        end
    end
    t[func] = true
end

function _M.print_root_dot_flow(ctx, conf)
    local s = _M.get_root_dot_flow(ctx, conf)
    print(s)
end

function _M.get_root_dot_flow(ctx, conf)
    local t = {}
    insert(t, [[digraph g {
rankdir=LR;
node [peripheries=1 fontname="helvetica bold" fontcolor="#ffffff"];
]])
    --local call = ctx.call

    local roots
    if conf.main then
        local t = { [conf.main] = true }
        get_roots(ctx, conf.main, t)
        roots = t
    else
        roots = ctx.call
    end

    for caller, _ in pairs(roots) do
        get_dot_flow(ctx, t, caller, conf)
    end

    insert(t, "}\n")

    return concat(t)
end

function tprint (tbl ,indent)
if not indent then indent = 0 end
  for k, v in pairs(tbl) do
    formatting = string.rep("  ", indent) .. k .. ": "
    if type(v) == "table" then
      print(formatting)
      tprint(v, indent+1)
    else
      print(formatting .. tostring(v))
    end
  end
end

function _M.parse_file(ctx, fname)
    local file = assert(io.open(fname))
    local s = file:read("*a")
    file:close()

    local t = _M.parse(ctx, s)
    -- tprint(t)

    return t
end

function _M.visit_tree(ctx, t)
    if DEBUG then
        log("begin visiting tree")
    end

    local conf = {
        Function    = { enter = process_function_enter,
                        leave = process_function_leave },
        Call        = { enter = process_call_enter },
        Set         = { enter = process_set_enter },
        Local       = { enter = process_set_enter },
        Localrec    = { enter = process_localrec_enter },
        Pair        = { enter = process_pair_enter },
        Block        = { enter = process_block_enter },
    }

    visit(t, conf, ctx)

    return t
end

return _M
