local gettext = require("gettext")

local chinese_messages = {
    ["Send files"] = {"发送文件", "傳送檔案"},
    ["Receive files"] = {"接收文件", "接收檔案"},
    ["Wi-Fi has no IPv4 address."] = {"Wi-Fi 没有 IPv4 地址。", "Wi-Fi 沒有 IPv4 位址。"},
    ["At most %1 files per transfer."] = {"每批最多传输 %1 个文件。", "每批最多傳輸 %1 個檔案。"},
    ["Starting LocalSend Lite…"] = {"正在启动 LocalSend Lite…", "正在啟動 LocalSend Lite…"},
    ["LocalSend Lite could not start: %1"] = {"LocalSend Lite 启动失败：%1", "LocalSend Lite 啟動失敗：%1"},
    ["Could not open the LocalSend ports on the Kindle Wi-Fi firewall"] = {
        "无法在 Kindle 防火墙上放行 LocalSend 端口。", "無法在 Kindle 防火牆上開放 LocalSend 連接埠。",
    },
    ["LocalSend Lite stopped: %1"] = {"LocalSend Lite 已停止：%1", "LocalSend Lite 已停止：%1"},
    ["Waiting for files as %1\n\nSave to %2"] = {
        "正在等待文件，本机昵称：%1\n\n保存到 %2", "正在等待檔案，本機暱稱：%1\n\n儲存至 %2",
    },
    ["Receiving from %1"] = {"正在从 %1 接收", "正在從 %1 接收"},
    ["Waiting for the next file…"] = {"正在等待下一个文件…", "正在等待下一個檔案…"},
    ["Current file: %1 (%2%)"] = {"当前文件：%1（%2%）", "目前檔案：%1（%2%）"},
    ["%1 other files receiving"] = {"另有 %1 个文件正在接收", "另有 %1 個檔案正在接收"},
    ["%1/%2 files saved · %3% · %4/s"] = {"已保存 %1/%2 个文件 · %3% · %4/s", "已儲存 %1/%2 個檔案 · %3% · %4/s"},
    ["Saved %1 of %2 files. Transfer timed out."] = {
        "已保存 %1/%2 个文件，传输超时。", "已儲存 %1/%2 個檔案，傳輸逾時。",
    },
    ["Saved %1 of %2 files. Sender cancelled."] = {
        "已保存 %1/%2 个文件，发送方已取消。", "已儲存 %1/%2 個檔案，傳送方已取消。",
    },
    ["Could not receive %1: %2"] = {"无法接收 %1：%2", "無法接收 %1：%2"},
    ["Connection timed out"] = {"连接超时", "連線逾時"},
    ["Truncated HTTP body"] = {"连接在文件传完前断开", "連線在檔案傳完前中斷"},
    ["Checksum mismatch"] = {"文件校验失败", "檔案校驗失敗"},
    ["Stop"] = {"停止", "停止"},
    ["Looking for nearby devices…"] = {"正在查找附近设备…", "正在尋找附近裝置…"},
    ["%1 (unencrypted)"] = {"%1（未加密）", "%1（未加密）"},
    ["Receiver PIN"] = {"接收方 PIN 码", "接收方 PIN 碼"},
    ["Cancel"] = {"取消", "取消"},
    ["Send"] = {"发送", "傳送"},
    ["Sending to %1…"] = {"正在发送到 %1…", "正在傳送至 %1…"},
    ["Sent %1 of %2 files."] = {"已发送 %1/%2 个文件。", "已傳送 %1/%2 個檔案。"},
    ["LocalSend Lite transfer complete."] = {"LocalSend Lite 传输完成。", "LocalSend Lite 傳輸完成。"},
    ["The receiver declined the transfer."] = {"接收方拒绝了传输。", "接收方拒絕了傳輸。"},
    ["The receiver is busy with another transfer."] = {
        "接收方正在处理另一批传输。", "接收方正在處理另一批傳輸。",
    },
    ["LocalSend Lite transfer failed: %1"] = {"LocalSend Lite 传输失败：%1", "LocalSend Lite 傳輸失敗：%1"},
    ["No files were accepted"] = {"没有文件被接受", "沒有檔案被接受"},
    ["Receive files from %1?"] = {"接收来自 %1 的文件？", "接收來自 %1 的檔案？"},
    ["+%1 more"] = {"另有 %1 个文件", "另有 %1 個檔案"},
    ["Accept"] = {"接受", "接受"},
    ["Decline"] = {"拒绝", "拒絕"},
    ["Received %1"] = {"已接收 %1", "已接收 %1"},
    ["Received %1 files."] = {"已接收 %1 个文件。", "已接收 %1 個檔案。"},
}

return function(message)
    local locale = gettext.current_lang:lower():gsub("-", "_"):match("^[^%.@]+")
    local translation = chinese_messages[message]
    if translation and locale and (locale == "zh" or locale:match("^zh_")) then
        local traditional = locale:match("^zh_hant") or locale == "zh_tw" or locale == "zh_hk" or locale == "zh_mo"
        return translation[traditional and 2 or 1]
    end
    return gettext(message)
end
