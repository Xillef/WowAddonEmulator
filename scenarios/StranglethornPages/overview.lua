-- Scenario: StranglethornPages overview window (German client), opened on login.
-- Shows every page state at once:
--   Chapter I:  page 1 in bags (green), page 4 twice in bags (red, x2),
--               page 6 in own bank (yellow), page 8 missing (gray)
--   Chapter II: page 10 in bags, page 11 in alt's bags, page 14 in alt's mailbox,
--               page 16 mailed to a foreign character
--   Chapter III: page 18 in bags + a copy in the bank (red, x2), rest missing
--   Chapter IV: quest 342 turned in -> collapsed as done
-- Item/quest IDs are the addon's own (Data.lua). The bank, alt and mail data are
-- preset SavedVariables, because the emulator has no bank/mail/quest API.

local Emu = __Emu

function GetLocale() return "deDE" end

Emu.SetPlayer { name = "Nadira", realm = "EmulatorRealm", class = "ROGUE", level = 40 }

local function page(itemID, n, count, slot)
    Emu.AddItem(itemID, { name = "Grüne Hügel des Schlingendorntals - Seite " .. n, count = count, bag = 0, slot = slot })
end
page(2725, 1, 1, 1)
page(2728, 4, 2, 2)
page(2734, 10, 1, 3)
page(2742, 18, 1, 4)

C_QuestLog = {
    IsOnQuest = function(questID) return questID == 338 end,
    IsQuestFlaggedCompleted = function(questID) return questID == 342 end,
}

local now = time()
Emu.SetSavedVariables {
    StranglethornPagesDB = {
        chars = {
            ["Nadira-EmulatorRealm"] = {
                bank = { [2730] = 1, [2742] = 1 }, bankTime = now - 2 * 3600,
            },
            ["Brakk-EmulatorRealm"] = {
                bags = { [2735] = 1 }, bagsTime = now - 26 * 3600,
                mailbox = { [2738] = 1 }, mailboxTime = now - 26 * 3600,
            },
        },
        sent = {
            { to = "Grimbold-OtherRealm", items = { [2740] = 1 }, time = now - 15 * 60 },
        },
        ui = { shown = true },
    },
}
