-- Rime lua 扩展：https://github.com/hchunhui/librime-lua
-------------------------------------------------------------
-- 日期时间
-- 提高权重的原因：因为在方案中设置了大于 1 的 initial_quality，导致 rq sj xq dt ts 产出的候选项在所有词语的最后。
function date_translator(input, seg, env)
    local config = env.engine.schema.config
    local date = config:get_string(env.name_space .. "/date") or "rq"
    local time = config:get_string(env.name_space .. "/time") or "sj"
    local week = config:get_string(env.name_space .. "/week") or "xq"
    local datetime = config:get_string(env.name_space .. "/datetime") or "dt"
    local timestamp = config:get_string(env.name_space .. "/timestamp") or "ts"
    -- 日期
    if (input == date) then
        local cand = Candidate("date", seg.start, seg._end, os.date("%Y-%m-%d"), "")
        cand.quality = 100
        yield(cand)
        local cand = Candidate("date", seg.start, seg._end, os.date("%Y/%m/%d"), "")
        cand.quality = 100
        yield(cand)
        local cand = Candidate("date", seg.start, seg._end, os.date("%Y.%m.%d"), "")
        cand.quality = 100
        yield(cand)
        local cand = Candidate("date", seg.start, seg._end, os.date("%Y 年 %m 月 %d 日"), "")
        cand.quality = 100
        yield(cand)
    end
    -- 时间
    if (input == time) then
        local cand = Candidate("time", seg.start, seg._end, os.date("%H:%M"), "")
        cand.quality = 100
        yield(cand)
        local cand = Candidate("time", seg.start, seg._end, os.date("%H:%M:%S"), "")
        cand.quality = 100
        yield(cand)
    end
    -- 星期
    if (input == week) then
        local weakTab = {'日', '一', '二', '三', '四', '五', '六'}
        local cand = Candidate("week", seg.start, seg._end, "星期" .. weakTab[tonumber(os.date("%w") + 1)], "")
        cand.quality = 100
        yield(cand)
        local cand = Candidate("week", seg.start, seg._end, "礼拜" .. weakTab[tonumber(os.date("%w") + 1)], "")
        cand.quality = 100
        yield(cand)
        local cand = Candidate("week", seg.start, seg._end, "周" .. weakTab[tonumber(os.date("%w") + 1)], "")
        cand.quality = 100
        yield(cand)
    end
    -- ISO 8601/RFC 3339 的时间格式 （固定东八区）（示例 2022-01-07T20:42:51+08:00）
    if (input == datetime) then
        local cand = Candidate("datetime", seg.start, seg._end, os.date("%Y-%m-%dT%H:%M:%S+08:00"), "")
        cand.quality = 100
        yield(cand)
        local cand = Candidate("time", seg.start, seg._end, os.date("%Y%m%d%H%M%S"), "")
        cand.quality = 100
        yield(cand)
    end
    -- 时间戳（十位数，到秒，示例 1650861664）
    if (input == timestamp) then
        local cand = Candidate("datetime", seg.start, seg._end, os.time(), "")
        cand.quality = 100
        yield(cand)
    end
end
-------------------------------------------------------------
-- 以词定字
-- https://github.com/BlindingDark/rime-lua-select-character
-- 删除了默认按键，需要在 key_binder（default.custom.yaml）下设置
local function utf8_sub(s, i, j)
    i = i or 1
    j = j or -1

    if i < 1 or j < 1 then
        local n = utf8.len(s)
        if not n then
            return nil
        end
        if i < 0 then
            i = n + 1 + i
        end
        if j < 0 then
            j = n + 1 + j
        end
        if i < 0 then
            i = 1
        elseif i > n then
            i = n
        end
        if j < 0 then
            j = 1
        elseif j > n then
            j = n
        end
    end

    if j < i then
        return ""
    end

    i = utf8.offset(s, i)
    j = utf8.offset(s, j + 1)

    if i and j then
        return s:sub(i, j - 1)
    elseif i then
        return s:sub(i)
    else
        return ""
    end
end

local function first_character(s)
    return utf8_sub(s, 1, 1)
end

local function last_character(s)
    return utf8_sub(s, -1, -1)
end

function select_character(key, env)
    local engine = env.engine
    local context = engine.context
    local commit_text = context:get_commit_text()
    local config = engine.schema.config

    -- local first_key = config:get_string('key_binder/select_first_character') or 'bracketleft'
    -- local last_key = config:get_string('key_binder/select_last_character') or 'bracketright'
    local first_key = config:get_string('key_binder/select_first_character')
    local last_key = config:get_string('key_binder/select_last_character')

    if (key:repr() == first_key and commit_text ~= "") then
        engine:commit_text(first_character(commit_text))
        context:clear()

        return 1 -- kAccepted
    end

    if (key:repr() == last_key and commit_text ~= "") then
        engine:commit_text(last_character(commit_text))
        context:clear()

        return 1 -- kAccepted
    end

    return 2 -- kNoop
end
-------------------------------------------------------------
-- 长词优先（提升「西安」「提案」「图案」「饥饿」等词汇的优先级）
-- 感谢&参考于： https://github.com/tumuyan/rime-melt
-- 修改：不提升英文和中英混输的
function long_word_filter(input, env)
    -- 仅在 wubi_pinyin 且输入为 4 码以上纯字母（拼音）时生效
    if env.engine.schema.schema_id == "wubi_pinyin" then
        local inp = env.engine.context.input or ""
        if not inp:match("^[a-z']+$") or #inp < 4 then
            for cand in input:iter() do
                yield(cand)
            end
            return
        end
    end

    -- 提升 count 个词语，插入到第 idx 个位置，默认 2、4。
    local config = env.engine.schema.config
    local count = config:get_int(env.name_space .. "/count") or 2
    local idx = config:get_int(env.name_space .. "/idx") or 4

    local l = {}
    local firstWordLength = 0 -- 记录第一个候选词的长度，提前的候选词至少要比第一个候选词长
    -- local s1 = 0 -- 记录筛选了多少个英语词条(只提升 count 个词的权重，并且对comment长度过长的候选进行过滤)
    local s2 = 0 -- 记录筛选了多少个汉语词条(只提升 count 个词的权重)

    local i = 1
    for cand in input:iter() do
        leng = utf8.len(cand.text)
        if (firstWordLength < 1 or i < idx) then
            i = i + 1
            firstWordLength = leng
            yield(cand)
		-- 不知道这两行是干嘛用的，似乎注释掉也没有影响。
		-- elseif #table > 30 then
		--     table.insert(l, cand)
		-- 注释掉了英文的
		-- elseif ((leng > firstWordLength) and (s1 < 2)) and (string.find(cand.text, "^[%w%p%s]+$")) then
		--     s1 = s1 + 1
		--     if (string.len(cand.text) / string.len(cand.comment) > 1.5) then
		--         yield(cand)
		--     end
		-- 换了个正则，否则中英混输的也会被提升
		-- elseif ((leng > firstWordLength) and (s2 < count)) and (string.find(cand.text, "^[%w%p%s]+$")==nil) then
        elseif ((leng > firstWordLength) and (s2 < count)) and (string.find(cand.text, "[%w%p%s]+") == nil) then
            yield(cand)
            s2 = s2 + 1
        else
            table.insert(l, cand)
        end
    end
    for i, cand in ipairs(l) do
        yield(cand)
    end
end
-------------------------------------------------------------
-- 降低部分英语单词在候选项的位置
-- https://dvel.me/posts/make-rime-en-better/#短单词置顶的问题
-- 感谢大佬 @[Shewer Lu](https://github.com/shewer) 指点
function reduce_english_filter(input, env)
    local config = env.engine.schema.config
    -- load data
    if not env.idx then
        env.idx = config:get_int(env.name_space .. "/idx") -- 要插入的位置
    end
    if not env.words then
        env.words = {} -- 要过滤的词
        local list = config:get_list(env.name_space .. "/words")
        for i = 0, list.size - 1 do
            local word = list:get_value_at(i).value
            env.words[word] = true
        end
    end

    -- filter start
    local code = env.engine.context.input
    if env.words[code] then
        local first_cand
        local index = 0
        for cand in input:iter() do
            index = index + 1
            if first_cand then
                yield(cand)
            else
                first_cand = cand
            end
            if index >= env.idx then
                yield(first_cand)
                break
            end
        end
    end

    -- yield other
    for cand in input:iter() do
        yield(cand)
    end
end
-------------------------------------------------------------
-- v 模式，单个字符优先
-- 因为设置了英文翻译器的 initial_quality 大于 1，导致输入「va」时，候选项是「van vain …… ā á ǎ à」
-- 把候选项应改为「ā á ǎ à …… van vain」，让单个字符的排在前面
function v_filter(input, env)
    local code = env.engine.context.input -- 当前编码
    local l = {}
    for cand in input:iter() do
        -- 特殊情况处理
        if (cand.text == "Vs.") then
            yield(cand)
        end
        -- 特殊情况处理
        local arr = {"1️⃣", "2️⃣", "3️⃣", "4️⃣", "5️⃣", "6️⃣", "7️⃣", "8️⃣", "9️⃣"}
        for _, v in ipairs(arr) do
            if (v == cand.text and string.len(code) == 2 and string.find(code, "v") == 1) then
                yield(cand)
                break
            end
        end
        -- 以 v 开头、2 个长度的编码、候选项为单个字符的，提到前面来。
        if (string.len(code) == 2 and string.find(code, "v") == 1 and utf8.len(cand.text) == 1) then
            yield(cand)
        else
            table.insert(l, cand)
        end
    end
    for _, cand in ipairs(l) do
        yield(cand)
    end
end
-------------------------------------------------------------
-- iRime 九宫格专用，将输入框的数字转为对应的拼音或英文
function irime_t9_preedit(input, env)
    for cand in input:iter() do
        if (string.find(cand.text, "%w+") ~= nil) then
            cand:get_genuine().preedit = cand.text
        else
            cand:get_genuine().preedit = cand.comment
        end
        yield(cand)
    end
end
-------------------------------------------------------------
-- wubi_pinyin 拼音增强
-- 功能：1) 拼音候选自动学习，写入 clover.userdb
--       2) 候选排序：准确五笔 → 准确拼音 → 推测五笔 → 推测拼音
--       3) 拼音候选显示五笔码提示
-------------------------------------------------------------

-- filter 与 commit 共享：上次编码、候选表、选词次数权重
local pinyin_learn_shared = {}

-- 五笔正向码表：code → [{text, weight}]（反查库通常只有主码，二码 js 需靠词库）
local wubi_forward_cache = { index = nil, set_by_code = nil }

-- 单次 filter 内复用的缓存（每次输入改变后清空）
local frame_cache = {
    inp = nil,
    charset_penalty = {},
    drop_bad = {},
    wubi_lookup = {},
}

local function reset_frame_cache(inp)
    if frame_cache.inp == inp then return end
    frame_cache.inp = inp
    frame_cache.charset_penalty = {}
    frame_cache.drop_bad = {}
    frame_cache.wubi_lookup = {}
end

local function is_chinese(text)
    return text and utf8.len(text) and utf8.len(text) >= 1
        and not text:match("^[%a%d%p%s]+$")
end

-- 常用字表（char_common.txt 按词频排序）；未收录字视为生僻/繁体，排序靠后
local charset_cache = { common_rank = {}, loaded = false }

-- 懒加载 ~/Library/Rime/char_common.txt（clover.base 高频 3500 简字）
local function load_charset_cache()
    if charset_cache.loaded then
        return
    end
    charset_cache.loaded = true
    local home = os.getenv("HOME") or ""
    local path = home .. "/Library/Rime/char_common.txt"
    local f = io.open(path, "r")
    if not f then
        return
    end
    local s = f:read("*a") or ""
    f:close()
    local rank = 0
    for _, code in utf8.codes(s) do
        rank = rank + 1
        charset_cache.common_rank[utf8.char(code)] = rank
    end
end

-- 候选含无法正常显示的字符（缺字、PUA、扩展区、emoji 等）则丢弃
-- 性能：按 text 缓存结果，避免每次都遍历 utf8 codes
local function should_drop_unrenderable(text)
    if not text or text == "" then
        return true
    end
    local cached = frame_cache.drop_bad[text]
    if cached ~= nil then
        return cached
    end
    local bad = false
    if text:find("?", 1, true) then
        bad = true
    else
        for _, code in utf8.codes(text) do
            if code == 0xFFFD
                or (code < 0x20 and code ~= 0x09)
                or (code >= 0xE000 and code <= 0xF8FF)
                or code >= 0x20000
                or (code >= 0xFE00 and code <= 0xFE0F)
                or (code >= 0xE0100 and code <= 0xE01EF)
                or (code >= 0x2600 and code <= 0x27BF)
                or code >= 0x1F000
                or code == 0x25A1 or code == 0x25AF then
                bad = true
                break
            end
        end
    end
    frame_cache.drop_bad[text] = bad
    return bad
end

-- 字符集排序惩罚分：越小越靠前（常用简字优先，生僻/繁体靠后）
-- 性能：按 text 缓存结果
local function charset_penalty(text)
    if not text then
        return 99999
    end
    local cached = frame_cache.charset_penalty[text]
    if cached then
        return cached
    end
    load_charset_cache()
    local rank_tbl = charset_cache.common_rank
    local n = utf8.len(text) or 1
    local sum = 0
    local worst = 0
    for _, code in utf8.codes(text) do
        local c = utf8.char(code)
        local rank = rank_tbl[c]
        if rank then
            sum = sum + rank
        elseif code >= 0x4E00 and code <= 0x9FFF then
            sum = sum + 9000
            if 9000 > worst then worst = 9000 end
        elseif code >= 0xF900 and code <= 0xFAFF then
            sum = sum + 12000
            if 12000 > worst then worst = 12000 end
        elseif code >= 0x3400 and code <= 0x4DBF then
            sum = sum + 15000
            if 15000 > worst then worst = 15000 end
        else
            sum = sum + 20000
            if 20000 > worst then worst = 20000 end
        end
    end
    local p = worst + sum / n
    frame_cache.charset_penalty[text] = p
    return p
end

-- 提取拼音编码；禁止用短于当前输入的 comment 码（如 smqk 时不采用 [smq]）
local function extract_pinyin_code(cand, inp)
    local inp_len = #inp
    local cand_end = cand._end
    if type(cand_end) == "number" and cand_end < inp_len then
        return nil
    end
    local comment = cand.comment or ""
    local bracket = comment:match("%[([^%]]+)%]")
    local plain = comment:match("^([%a']+)$")
    local hint = bracket or plain
    if hint then
        if hint == inp then
            return inp .. " "
        end
        if #hint < inp_len and inp:sub(1, #hint) == hint then
            return nil
        end
    end
    if comment ~= "" and comment:match("^[%a%s']+$") and not comment:match("%d") then
        local c = comment:gsub("%s+", " "):match("^%s*(.-)%s*$")
        if c == inp then
            return inp .. " "
        end
    end
    if inp and #inp >= 2 then
        return inp .. " "
    end
    return nil
end

-- 匹配等级：0=编码吃满 1=普通 2=仅前缀（如 smq 对 smqk，排后）
local function candidate_match_rank(cand, inp, inp_len)
    local cand_end = cand._end
    if type(cand_end) == "number" and cand_end >= inp_len then
        return 0
    end
    local hint = (cand.comment or ""):match("%[([^%]]+)%]")
    if hint and #hint < inp_len and inp:sub(1, #hint) == hint then
        return 2
    end
    return 1
end

-- 候选类型权重：user_phrase 永远比 phrase 靠前，避免被 charset/quality 打散
local function type_rank(cand)
    local t = cand.type
    if t == "user_phrase" or t == "user_table" then
        return 0
    end
    if t == "phrase" or t == "table" then
        return 1
    end
    return 2
end

-- 桶内排序：匹配度 → 类型（user_phrase 优先）→ 学习权重 → 引擎 quality → 常用字
-- 性能：cand.quality/text/type 只取一次；charset_penalty 已缓存
local function sort_bucket_by_match_and_weight(cands, inp)
    local n = #cands
    if n <= 1 then
        return cands
    end
    local inp_len = #inp
    local meta = {}
    local weights = pinyin_learn_shared.weights or {}
    for i = 1, n do
        local c = cands[i]
        local text = c.text or ""
        meta[i] = {
            cand = c,
            rank = candidate_match_rank(c, inp, inp_len),
            type_r = type_rank(c),
            weight = weights[inp .. "\0" .. text] or 0,
            quality = type(c.quality) == "number" and c.quality or 0,
            penalty = charset_penalty(text),
        }
    end
    table.sort(meta, function(a, b)
        if a.rank ~= b.rank then return a.rank < b.rank end
        if a.type_r ~= b.type_r then return a.type_r < b.type_r end
        if a.weight ~= b.weight then return a.weight > b.weight end
        if a.quality ~= b.quality then return a.quality > b.quality end
        return a.penalty < b.penalty
    end)
    for i = 1, n do
        cands[i] = meta[i].cand
    end
    return cands
end

-- 学习权重持久化路径（重启后仍生效）
local function learn_weight_path()
    return (os.getenv("HOME") or "") .. "/Library/Rime/user_phrase_boost.txt"
end

-- 启动时从磁盘加载历史权重
local function ensure_learn_weights_loaded()
    if pinyin_learn_shared.weights_loaded then return end
    pinyin_learn_shared.weights_loaded = true
    pinyin_learn_shared.weights = pinyin_learn_shared.weights or {}
    local f = io.open(learn_weight_path(), "r")
    if not f then return end
    for line in f:lines() do
        local inp, text, w = line:match("^([^\t]+)\t([^\t]+)\t(%d+)$")
        if inp and text and w then
            pinyin_learn_shared.weights[inp .. "\0" .. text] = tonumber(w) or 0
        end
    end
    f:close()
end

-- 把权重表写盘（每次学习后调用，规模小，开销低）
local function save_learn_weights()
    local f = io.open(learn_weight_path(), "w")
    if not f then return end
    for key, w in pairs(pinyin_learn_shared.weights or {}) do
        local nul = key:find("\0", 1, true)
        if nul then
            local inp = key:sub(1, nul - 1)
            local text = key:sub(nul + 1)
            f:write(inp, "\t", text, "\t", tostring(w), "\n")
        end
    end
    f:close()
end

-- 写入用户词典的权重：随选词次数递增（按「编码+词」计次）
local function learn_weight_for_key(key, base, step)
    base = base or 24
    step = step or 12
    ensure_learn_weights_loaded()
    local w = (pinyin_learn_shared.weights[key] or base) + step
    if w > 9999 then w = 9999 end
    pinyin_learn_shared.weights[key] = w
    return math.min(w, 99)
end

local function update_userdict_entry(engine, schema_id, ns, text, code, weight)
    local ok, schema = pcall(Schema, schema_id)
    if not ok or not schema then
        return false
    end
    local mok, mem = pcall(Memory, engine, schema, ns)
    if not mok or not mem or not mem.update_userdict then
        return false
    end
    local entry = DictEntry()
    entry.text = text
    entry.custom_code = code
    pcall(function()
        mem:update_userdict(entry, weight, "")
    end)
    return true
end

-- 记录候选；仅编码吃满（cand._end >= 输入长度）才允许学习
local function record_candidate_for_learn(cand, bucket, inp, inp_len, min_learn)
    local text = cand.text or ""
    if text == "" or not utf8.len(text) then
        return
    end
    local cand_end = cand._end
    if type(cand_end) ~= "number" or cand_end < inp_len then
        return
    end
    if candidate_match_rank(cand, inp, inp_len) >= 2 then
        return
    end
    local code
    if bucket == 1 or bucket == 3 then
        code = inp .. " "
    else
        code = extract_pinyin_code(cand, inp) or (inp .. " ")
    end
    local code_trim = code:gsub("%s+$", "")
    if code_trim ~= inp then
        return
    end
    if bucket == 1 or bucket == 3 then
        if #code_trim < 1 then
            return
        end
    else
        if #code_trim < min_learn or utf8.len(text) < 2 then
            return
        end
    end
    pinyin_learn_shared.candidates[text] = {code = code, bucket = bucket}
end

-- 读取 pinyin_learn_filter 配置项；每个 env 缓存，避免每次候选都查 schema
local function pinyin_learn_cfg(env, key, default)
    env._cfg_cache = env._cfg_cache or {}
    local cached = env._cfg_cache[key]
    if cached ~= nil then
        if cached == false then return default end
        return cached
    end
    local config = env.engine.schema.config
    local v = config:get_int("pinyin_learn_filter/" .. key)
    if v ~= nil then
        env._cfg_cache[key] = v
        return v
    end
    local b = config:get_bool("pinyin_learn_filter/" .. key)
    if b ~= nil then
        env._cfg_cache[key] = b
        return b
    end
    env._cfg_cache[key] = false
    return default
end

-- 含元音的字母串视为拼音输入（仅用于 ≥4 码的拼音优先模式）
local function looks_like_pinyin(inp)
    return inp and inp:match("[aeiouAEIOU]") ~= nil
end

-- 编码不足 4 码时一律按五笔模式（避免 yaa、smq 等被当成拼音）
local function prefer_wubi_mode(inp_len, env)
    local pinyin_min = pinyin_learn_cfg(env, "pinyin_first_min_len", 4)
    return inp_len < pinyin_min
end

-- 加载 wubi86.dict.yaml 正向索引（编码与输入完全一致的字/词）
-- 同时维护 set_by_code 用于 O(1) 判断 text 是否在该 code 下
local function ensure_wubi_forward_index()
    if wubi_forward_cache.index then
        return wubi_forward_cache.index
    end
    local index = {}
    local set_by_code = {}
    local home = os.getenv("HOME") or ""
    local path = home .. "/Library/Rime/wubi86.dict.yaml"
    local f = io.open(path, "r")
    if f then
        local past_header = false
        for line in f:lines() do
            if line == "..." then
                past_header = true
            elseif past_header and line ~= "" and line:byte(1) ~= 35 then
                local t1 = line:find("\t", 1, true)
                if t1 then
                    local text = line:sub(1, t1 - 1)
                    local rest = line:sub(t1 + 1)
                    local t2 = rest:find("\t", 1, true)
                    local code = t2 and rest:sub(1, t2 - 1) or rest
                    if code:match("^[%a']+$") then
                        local weight = 0
                        if t2 then
                            local w = rest:sub(t2 + 1):match("^(%d+)")
                            weight = w and tonumber(w) or 0
                        end
                        if not index[code] then
                            index[code] = {}
                            set_by_code[code] = {}
                        end
                        table.insert(index[code], {text = text, weight = weight})
                        set_by_code[code][text] = true
                    end
                end
            end
        end
        f:close()
        for _, list in pairs(index) do
            table.sort(list, function(a, b)
                return a.weight > b.weight
            end)
        end
    end
    wubi_forward_cache.index = index
    wubi_forward_cache.set_by_code = set_by_code
    return index
end

-- 词库正向表：该编码下是否存在此候选文本（O(1) set 查找）
local function wubi_forward_has_text(text, inp)
    ensure_wubi_forward_index()
    local set = wubi_forward_cache.set_by_code[inp]
    return set and set[text] == true
end

-- 从候选 comment 提取五笔码（支持 [js] 或裸码 js）
local function wubi_code_from_comment(cand)
    if not cand then
        return nil
    end
    local comment = cand.comment or ""
    local plain = comment:match("^([%a']+)$")
    if plain then
        return plain
    end
    local hint = comment:match("%[([^%]]+)%]")
    if hint and hint:match("^[%a']+$") then
        return hint
    end
    return nil
end

-- 缓存 wubi_rev:lookup
local function wubi_lookup_cached(wubi_rev, text)
    if not wubi_rev or not text then return "" end
    local v = frame_cache.wubi_lookup[text]
    if v ~= nil then return v end
    v = wubi_rev:lookup(text) or ""
    frame_cache.wubi_lookup[text] = v
    return v
end

-- 判断五笔全码是否与当前输入一致（字/词；优先正向词库，其次 comment / 反查）
local function wubi_code_matches_input(text, inp, wubi_rev, cand)
    if not text or not inp or inp == "" then
        return false
    end
    if wubi_forward_has_text(text, inp) then
        return true
    end
    if cand then
        local hint = wubi_code_from_comment(cand)
        if hint == inp then
            return true
        end
    end
    local code = wubi_lookup_cached(wubi_rev, text)
    if code == "" then
        return false
    end
    for token in code:gmatch("%S+") do
        if token == inp then
            return true
        end
    end
    return false
end

-- 从各桶抽出与输入全码一致的五笔候选，按词库权重置顶输出
local function pull_exact_wubi_pins(buckets, inp, wubi_rev)
    local index = ensure_wubi_forward_index()
    local entries = index[inp]
    if not entries or #entries == 0 then
        return {}, buckets
    end
    local text_rank = {}
    for i, entry in ipairs(entries) do
        text_rank[entry.text] = i
    end
    local pins = {}
    local pinned_text = {}
    for b = 1, 5 do
        local kept = {}
        for _, cand in ipairs(buckets[b]) do
            local t = cand.text or ""
            if text_rank[t] then
                if not pinned_text[t] then
                    pinned_text[t] = true
                    table.insert(pins, cand)
                end
            else
                table.insert(kept, cand)
            end
        end
        buckets[b] = kept
    end
    table.sort(pins, function(a, b)
        local ra = text_rank[a.text or ""] or 99999
        local rb = text_rank[b.text or ""] or 99999
        if ra ~= rb then
            return ra < rb
        end
        local na = utf8.len(a.text or "") or 0
        local nb = utf8.len(b.text or "") or 0
        if na ~= nb then
            return na < nb
        end
        return charset_penalty(a.text) < charset_penalty(b.text)
    end)
    return pins, buckets
end

-- 五笔桶内排序：全码精确匹配（字/词，含二码 js→果）最前，其次单字，再前缀补全词组
local function wubi_candidate_priority(cand, inp, inp_len, wubi_rev)
    local n = utf8.len(cand.text or "") or 0
    local cand_end = cand._end
    local full = type(cand_end) == "number" and cand_end >= inp_len
    local exact = wubi_code_matches_input(cand.text, inp, wubi_rev, cand)
    if full and exact then
        return 0
    end
    if exact then
        return 1
    end
    if n == 1 and full then
        return 2
    end
    if full then
        return 3
    end
    if n == 1 then
        return 4
    end
    return 5
end

local function sort_wubi_bucket_precise(cands, inp, inp_len, wubi_rev)
    local n = #cands
    if n <= 1 then
        return cands
    end
    local meta = {}
    local weights = pinyin_learn_shared.weights or {}
    for i = 1, n do
        local c = cands[i]
        local text = c.text or ""
        meta[i] = {
            cand = c,
            prio = wubi_candidate_priority(c, inp, inp_len, wubi_rev),
            type_r = type_rank(c),
            weight = weights[inp .. "\0" .. text] or 0,
            penalty = charset_penalty(text),
        }
    end
    table.sort(meta, function(a, b)
        if a.prio ~= b.prio then return a.prio < b.prio end
        if a.type_r ~= b.type_r then return a.type_r < b.type_r end
        if a.weight ~= b.weight then return a.weight > b.weight end
        return a.penalty < b.penalty
    end)
    for i = 1, n do
        cands[i] = meta[i].cand
    end
    return cands
end

-- 桶内按常用字优先排序（仅字符集维度）；同样按 text 预算惩罚分
local function sort_bucket_by_charset(cands)
    local n = #cands
    if n <= 1 then
        return cands
    end
    local pens = {}
    for i = 1, n do
        pens[cands[i]] = charset_penalty(cands[i].text)
    end
    table.sort(cands, function(a, b)
        return pens[a] < pens[b]
    end)
    return cands
end

-- 懒加载五笔反查数据库
local function ensure_wubi_rev(env)
    if not env.wubi_rev then
        local ok, db = pcall(ReverseDb, "build/wubi86.reverse.bin")
        env.wubi_rev = ok and db or nil
    end
    return env.wubi_rev
end

-- 去掉 comment 里 clover emoji/符号联想产生的 ☯、🍁、◾ 等，只保留拼音/五笔类 ASCII 注释
local function strip_symbol_tips_from_comment(comment)
    if not comment or comment == "" then
        return ""
    end
    local result = {}
    for _, code in utf8.codes(comment) do
        local c = utf8.char(code)
        if c:match("^[%a%d%[%]%(%)%:'%s%.%,]$") or code == 0xFC or code == 0xDC then
            result[#result + 1] = c
        end
    end
    return table.concat(result):match("^%s*(.-)%s*$") or ""
end

local function append_wubi_comment(cand, wubi_rev)
    if not wubi_rev then return end
    local txt = cand.text or ""
    if not is_chinese(txt) then return end
    local wubi_code = wubi_rev:lookup(txt)
    if wubi_code and wubi_code ~= "" then
        -- 只取第一个五笔码（多个码用空格分隔）
        wubi_code = wubi_code:match("^%S+")
        local g = cand:get_genuine()
        local orig = g.comment or ""
        if not orig:match("%[" .. wubi_code .. "%]") then
            g.comment = orig .. "[" .. wubi_code .. "]"
        end
    end
end

-- 整理候选 comment：清除符号提示；仅拼音候选追加五笔码（可配置）
local function prepare_candidate_comment(cand, wubi_rev, bucket, env)
    local g = cand:get_genuine()
    g.comment = strip_symbol_tips_from_comment(g.comment or "")
    local pinyin_only = pinyin_learn_cfg(env, "wubi_comment_on_pinyin_only", true)
    if not pinyin_only or bucket == 2 or bucket == 4 then
        append_wubi_comment(cand, wubi_rev)
    end
end

-- 编码长度分档：
--   <4：五笔优先  |  ≥4：拼音优先  |  <5：准确五笔（单字/词）始终排在最前
local function bucket_order_for_input(inp_len, is_letters, env)
    if not is_letters then
        return {1, 2, 3, 4, 5}
    end
    local pinyin_min = pinyin_learn_cfg(env, "pinyin_first_min_len", 4)
    local wubi_front_max = pinyin_learn_cfg(env, "wubi_accurate_front_max_len", 4)

    if inp_len > wubi_front_max then
        if inp_len >= pinyin_min then
            return {2, 4, 1, 3, 5}
        end
        return {1, 3, 2, 4, 5}
    end

    if inp_len < pinyin_min then
        return {1, 3, 2, 4, 5}
    end
    return {1, 2, 4, 3, 5}
end

-- 推测桶限流
local function allow_in_bucket(b, bucket_counts, inp, inp_len, is_letters, env)
    if not is_letters then
        return true
    end
    local pinyin_min = pinyin_learn_cfg(env, "pinyin_first_min_len", 4)
    if b == 3 and inp_len >= pinyin_min and not prefer_wubi_mode(inp_len, env) and looks_like_pinyin(inp) then
        return false
    end
    if b ~= 3 and b ~= 4 then
        return true
    end
    local max_len = pinyin_learn_cfg(env, "max_guess_input_len", 6)
    local max_n = pinyin_learn_cfg(env, "max_guess_per_bucket", 3)
    if inp_len <= max_len and bucket_counts[b] >= max_n then
        return false
    end
    return true
end

-- 候选分桶（基于 cand.type、cand._end 覆盖范围、cand.quality）：
--   准确 = type 为 table/phrase 且 cand._end 覆盖完整输入（候选匹配了全部输入）
--   推测 = completion/sentence/未覆盖完整输入（前缀补全、自动造句、部分匹配）
--   1=准确五笔  2=准确拼音  3=推测五笔  4=推测拼音
local function classify_candidate(cand, inp, inp_len, env, wubi_rev)
    local t = cand.type
    local t_str = (type(t) == "string") and t or ""
    local cand_end = cand._end
    local full_match = type(cand_end) == "number" and cand_end >= inp_len
    local n = utf8.len(cand.text or "") or 0

    -- 五笔全码与输入完全一致（二码/三码/四码，字或词）→ 准确五笔桶，优先于前缀补全
    if wubi_code_matches_input(cand.text, inp, wubi_rev, cand) then
        return 1
    end

    if prefer_wubi_mode(inp_len, env) then
        if t_str == "table" or t_str == "user_table" then
            return 1
        end
        if full_match and n == 1 then
            return 1
        end
        if t_str == "phrase" or t_str == "user_phrase" then
            if full_match then
                return 3
            end
        end
        if full_match then
            return 3
        end
        local quality = cand.quality
        if type(quality) == "number" and quality > 50 then
            return 3
        end
        return 4
    end

    if t_str == "table" then
        return 1
    end
    if t_str == "user_table" then
        if looks_like_pinyin(inp) then
            if full_match then
                return 2
            end
            return 4
        end
        return 1
    end

    if t_str == "phrase" or t_str == "user_phrase" then
        if full_match then
            return 2
        end
    end

    local quality = cand.quality
    if type(quality) == "number" and quality > 50 then
        return 3
    else
        return 4
    end
end

-------------------------------------------------------------
-- pinyin_learn_filter：候选过滤器
-- 收集全部候选 → 按 4 级优先级分桶 → 记录拼音编码 → 添加五笔码提示 → 按桶顺序输出
-------------------------------------------------------------
function pinyin_learn_filter(input, env)
    if env.engine.schema.schema_id ~= "wubi_pinyin" then
        for cand in input:iter() do yield(cand) end
        return
    end

    local ctx = env.engine.context
    local inp = ctx.input
    if not inp or inp == "" then
        for cand in input:iter() do yield(cand) end
        return
    end

    reset_frame_cache(inp)
    ensure_learn_weights_loaded()
    local wubi_rev = ensure_wubi_rev(env)
    local is_letters = inp:match("^[a-z']+$") ~= nil
    local is_alpha = is_letters and #inp >= 2

    if is_letters then
        pinyin_learn_shared.candidates = {}
        pinyin_learn_shared.last_input = inp
    end

    -- 收集并分桶：1=准确五笔 2=准确拼音 3=推测五笔 4=推测拼音 5=其他
    local inp_len = #inp
    local buckets = {{}, {}, {}, {}, {}}
    local bucket_counts = {0, 0, 0, 0, 0}
    local min_learn = pinyin_learn_cfg(env, "min_learn_code_len", 3)
    local filter_bad = pinyin_learn_cfg(env, "filter_unrenderable", true)
    load_charset_cache()
    if is_letters then
        ensure_wubi_forward_index()
    end

    for cand in input:iter() do
        if filter_bad and should_drop_unrenderable(cand.text) then
            -- 跳过缺字、问号、PUA 等无法正常显示的候选
        elseif is_chinese(cand.text) then
            local b = classify_candidate(cand, inp, inp_len, env, wubi_rev)
            if allow_in_bucket(b, bucket_counts, inp, inp_len, is_letters, env) then
                if is_letters then
                    record_candidate_for_learn(cand, b, inp, inp_len, min_learn)
                end
                local bk = buckets[b]
                bk[#bk + 1] = cand
                bucket_counts[b] = bucket_counts[b] + 1
            end
        else
            table.insert(buckets[5], cand)
        end
    end

    local bucket_order = bucket_order_for_input(inp_len, is_letters, env)
    local wubi_front_max = pinyin_learn_cfg(env, "wubi_accurate_front_max_len", 4)

    -- 全码置顶：如 js→果（反查无主码 js 时仍排第一）
    local pinned = {}
    if is_letters then
        pinned, buckets = pull_exact_wubi_pins(buckets, inp, wubi_rev)
    end
    for _, cand in ipairs(pinned) do
        if is_chinese(cand.text) then
            prepare_candidate_comment(cand, wubi_rev, 1, env)
        end
        yield(cand)
    end

    for _, b in ipairs(bucket_order) do
        local list = buckets[b]
        if (b == 1 or b == 3) and is_letters then
            list = sort_wubi_bucket_precise(list, inp, inp_len, wubi_rev)
        elseif #list > 1 and is_letters then
            list = sort_bucket_by_match_and_weight(list, inp)
        elseif #list > 1 then
            list = sort_bucket_by_charset(list)
        end
        for _, cand in ipairs(list) do
            if is_chinese(cand.text) then
                prepare_candidate_comment(cand, wubi_rev, b, env)
            end
            yield(cand)
        end
    end
end

-------------------------------------------------------------
-- pinyin_commit_processor：按键处理器
-- 监听 commit 事件，将拼音候选写入 clover.userdb
-------------------------------------------------------------
function pinyin_commit_processor(key, env)
    return 2 -- kNoop
end

local function pinyin_commit_init(env)
    if env.pinyin_notifier_connected then return end

    local engine_ref = env.engine
    env.pinyin_notifier = engine_ref.context.commit_notifier:connect(function()
        pcall(function()
        if engine_ref.schema.schema_id ~= "wubi_pinyin" then
            return
        end

        local inp = pinyin_learn_shared.last_input
        local pc = pinyin_learn_shared.candidates
        if not inp or inp == "" or not pc then
            return
        end

        local hist = engine_ref.context.commit_history
        if not hist or hist:size() == 0 then
            return
        end

        local rec = hist:back()
        local text = rec and rec.text
        if not text or text == "" or not is_chinese(text) then
            return
        end

        local info = pc[text]
        if type(info) == "string" then
            info = {code = info, bucket = 4}
        end
        if not info then
            return
        end

        local code = info.code
        if not code or code == "" then
            return
        end
        local code_trim = code:gsub("%s+$", "")
        if code_trim ~= inp then
            return
        end

        local cfg = engine_ref.schema.config
        local base = cfg and cfg:get_int("pinyin_learn_filter/learn_weight_base") or 24
        local step = cfg and cfg:get_int("pinyin_learn_filter/learn_weight_step") or 12
        local weight_key = inp .. "\0" .. text
        local weight = learn_weight_for_key(weight_key, base, step)
        local bucket = info.bucket or 4

        if bucket == 1 or bucket == 3 then
            update_userdict_entry(engine_ref, "wubi_pinyin", "translator", text, code, weight)
        else
            update_userdict_entry(engine_ref, "clover", "translator", text, code, weight)
        end

        save_learn_weights()
        pinyin_learn_shared.candidates = nil
        end)
    end)
    env.pinyin_notifier_connected = true
end

local function pinyin_commit_fini(env)
    if env.pinyin_notifier and env.pinyin_notifier_connected then
        env.pinyin_notifier:disconnect()
        env.pinyin_notifier_connected = nil
    end
end

pinyin_commit_processor.init = pinyin_commit_init
pinyin_commit_processor.fini = pinyin_commit_fini
-------------------------------------------------------------
-- Unicode 输入
-- 复制自： https://github.com/shewer/librime-lua-script/blob/main/lua/component/unicode.lua
function unicode(input, seg, env)
    local ucodestr = seg:has_tag("unicode") and input:match("U(%x+)")
    if ucodestr and #ucodestr > 1 then
        local code = tonumber(ucodestr, 16)
        local text = utf8.char(code)
        yield(Candidate("unicode", seg.start, seg._end, text, string.format("U%x", code)))
        if #ucodestr < 5 then
            for i = 0, 15 do
                local text = utf8.char(code * 16 + i)
                yield(Candidate("unicode", seg.start, seg._end, text, string.format("U%x~%x", code, i)))
            end
        end
    end
end
-------------------------------------------------------------
