-- Nicknames are protocol data, independent of KOReader's translation catalogs.
-- Use complete phrases where adjective order or agreement depends on the noun.
local localized_names = {
    ar = {
        "تفاحة مرحة", "كمثرى هادئة", "خوخة لطيفة", "فراولة سعيدة",
        "ليمونة مشمسة", "موزة نشيطة", "برتقالة فضولية", "كرزة محظوظة",
        "رمانة شجاعة", "أناناسة ذهبية", "تينة خجولة", "مانجو باسمة",
    },
    de = {
        "Fröhlicher Apfel", "Ruhige Birne", "Mutiger Pfirsich", "Neugierige Mango",
        "Sonnige Zitrone", "Goldene Aprikose", "Sanfte Pflaume", "Glückliche Erdbeere",
        "Freche Kirsche", "Flotte Kiwi", "Verträumte Feige", "Strahlende Orange",
    },
    es = {
        "Manzana alegre", "Pera tranquila", "Melocotón valiente", "Mango curioso",
        "Limón soleado", "Uva dorada", "Ciruela amable", "Fresa afortunada",
        "Cereza traviesa", "Kiwi veloz", "Higo soñador", "Naranja radiante",
    },
    fr = {
        "Pomme joyeuse", "Poire tranquille", "Pêche courageuse", "Mangue curieuse",
        "Citron ensoleillé", "Raisin doré", "Prune paisible", "Fraise chanceuse",
        "Cerise espiègle", "Kiwi rapide", "Figue rêveuse", "Orange radieuse",
    },
    he = {
        "תפוח עליז", "אגס רגוע", "אפרסק אמיץ", "מנגו סקרן",
        "לימון שמשי", "ענב זהוב", "שזיף עדין", "תות שמח",
        "דובדבן שובב", "קיווי זריז", "תאנה חולמנית", "תפוז זוהר",
    },
    hi = {
        "हँसमुख सेब", "शांत नाशपाती", "बहादुर आड़ू", "जिज्ञासु आम",
        "चमकीला नींबू", "सुनहरा अंगूर", "नटखट चेरी", "फुर्तीला कीवी",
        "शर्मीला अमरूद", "खुश संतरा", "प्यारी लीची", "मस्त केला",
    },
    id = {
        "Apel Ceria", "Pir Tenang", "Persik Pemberani", "Mangga Penasaran",
        "Lemon Cerah", "Anggur Emas", "Plum Ramah", "Stroberi Beruntung",
        "Ceri Usil", "Kiwi Lincah", "Tin Pemalu", "Jeruk Bahagia",
    },
    it = {
        "Mela allegra", "Pera tranquilla", "Pesca coraggiosa", "Mango curioso",
        "Limone solare", "Uva dorata", "Prugna gentile", "Fragola fortunata",
        "Ciliegia vivace", "Kiwi veloce", "Fico sognatore", "Arancia sorridente",
    },
    nl = {
        "Vrolijke appel", "Kalme peer", "Dappere perzik", "Nieuwsgierige mango",
        "Zonnige citroen", "Gouden druif", "Vriendelijke pruim", "Gelukkige aardbei",
        "Ondeugende kers", "Snelle kiwi", "Dromerige vijg", "Stralende sinaasappel",
    },
    pl = {
        "Wesołe jabłko", "Spokojna gruszka", "Odważna brzoskwinia", "Ciekawe mango",
        "Słoneczna cytryna", "Złote winogrono", "Łagodna śliwka", "Szczęśliwa truskawka",
        "Psotna wiśnia", "Zwinne kiwi", "Marzycielska figa", "Promienna pomarańcza",
    },
    pt_br = {
        "Maçã Alegre", "Pera Tranquila", "Pêssego Corajoso", "Manga Curiosa",
        "Limão Radiante", "Uva Dourada", "Ameixa Gentil", "Morango Sortudo",
        "Cereja Sapeca", "Kiwi Veloz", "Figo Sonhador", "Abacaxi Sorridente",
    },
    pt_pt = {
        "Maçã Alegre", "Pera Tranquila", "Pêssego Corajoso", "Manga Curiosa",
        "Limão Radiante", "Uva Dourada", "Ameixa Gentil", "Morango Sortudo",
        "Cereja Traquina", "Kiwi Veloz", "Figo Sonhador", "Ananás Sorridente",
    },
    ru = {
        "Весёлое яблоко", "Тихая груша", "Смелый персик", "Любопытное манго",
        "Солнечный лимон", "Золотой виноград", "Добрая слива", "Удачливая клубника",
        "Озорная вишня", "Шустрый киви", "Мечтательный инжир", "Лучистый апельсин",
    },
    th = {
        "แอปเปิลร่าเริง", "ลูกแพร์ใจเย็น", "ลูกพีชกล้าหาญ", "มะม่วงช่างสงสัย",
        "เลมอนสดใส", "องุ่นสีทอง", "ลูกพลัมใจดี", "สตรอว์เบอร์รีโชคดี",
        "เชอร์รีจอมซน", "กีวีว่องไว", "ลูกฟิกช่างฝัน", "ส้มยิ้มแย้ม",
    },
    tr = {
        "Neşeli Elma", "Sakin Armut", "Cesur Şeftali", "Meraklı Mango",
        "Işıltılı Limon", "Altın Üzüm", "Nazik Erik", "Şanslı Çilek",
        "Yaramaz Kiraz", "Çevik Kivi", "Hayalperest İncir", "Gülen Portakal",
    },
    uk = {
        "Веселе яблуко", "Тиха груша", "Сміливий персик", "Допитливе манго",
        "Сонячний лимон", "Золотий виноград", "Лагідна слива", "Щаслива полуниця",
        "Пустотлива вишня", "Спритний ківі", "Мрійливий інжир", "Усміхнений апельсин",
    },
    vi = {
        "Táo vui vẻ", "Lê điềm tĩnh", "Đào dũng cảm", "Xoài tò mò",
        "Chanh rạng rỡ", "Nho vàng", "Mận hiền lành", "Dâu tây may mắn",
        "Anh đào tinh nghịch", "Kiwi nhanh nhẹn", "Sung mơ mộng", "Cam tươi cười",
    },
}

local word_lists = {
    en = {
        adjectives = { "Amber", "Bright", "Calm", "Cheerful", "Curious", "Gentle",
            "Golden", "Happy", "Jolly", "Lucky", "Quiet", "Sunny" },
        fruits = { "Apricot", "Cherry", "Clementine", "Fig", "Guava", "Kiwi",
            "Lemon", "Mango", "Orange", "Peach", "Pear", "Plum" },
        separator = " ",
    },
    ja = {
        adjectives = { "元気な", "穏やかな", "陽気な", "おちゃめな", "すばしっこい", "やさしい",
            "のんびりした", "しっかりした", "明るい", "かしこい", "がんばり屋の", "幸運な" },
        fruits = { "りんご", "さくらんぼ", "みかん", "いちじく", "ぶどう", "キウイ",
            "レモン", "マンゴー", "いちご", "もも", "なし", "すもも" },
        separator = "",
    },
    ko = {
        adjectives = { "명랑한", "온화한", "차분한", "씩씩한", "호기심 많은", "다정한",
            "반짝이는", "행복한", "장난꾸러기", "운 좋은", "조용한", "햇살 같은" },
        fruits = { "살구", "체리", "귤", "무화과", "포도", "키위",
            "레몬", "망고", "딸기", "복숭아", "배", "자두" },
        separator = " ",
    },
    zh_cn = {
        adjectives = { "热心", "活泼", "机灵", "大方", "好奇", "温柔",
            "勇敢", "开心", "俏皮", "幸运", "安静", "阳光" },
        fruits = { "杏子", "樱桃", "橘子", "无花果", "番石榴", "猕猴桃",
            "柠檬", "芒果", "甜橙", "蜜桃", "雪梨", "李子" },
        separator = "的",
    },
    zh_tw = {
        adjectives = { "熱心", "活潑", "機靈", "大方", "好奇", "溫柔",
            "勇敢", "開心", "俏皮", "幸運", "安靜", "陽光" },
        fruits = { "杏桃", "櫻桃", "橘子", "無花果", "芭樂", "奇異果",
            "檸檬", "芒果", "柳橙", "水蜜桃", "水梨", "李子" },
        separator = "的",
    },
}

local function nicknameLocale(locale)
    local normalized = (locale or ""):lower():gsub("-", "_"):match("^[%a_]+") or ""
    local language = normalized:match("^%a+")
    if language == "zh" then
        if normalized:match("^zh_hant") or normalized == "zh_tw"
            or normalized == "zh_hk" or normalized == "zh_mo" then
            return "zh_tw"
        end
        return "zh_cn"
    end
    if word_lists[normalized] or localized_names[normalized] then return normalized end
    if language == "pt" then return "pt_pt" end
    return language
end

return function(fingerprint, locale)
    local nickname_locale = nicknameLocale(locale)
    local translated_names = localized_names[nickname_locale]
    if translated_names then
        local name_index = tonumber(fingerprint:sub(1, 8), 16) % #translated_names + 1
        return translated_names[name_index]
    end

    local words = word_lists[nickname_locale] or word_lists.en
    local adjective_index = tonumber(fingerprint:sub(1, 4), 16) % #words.adjectives + 1
    local fruit_index = tonumber(fingerprint:sub(5, 8), 16) % #words.fruits + 1
    return words.adjectives[adjective_index] .. words.separator .. words.fruits[fruit_index]
end
