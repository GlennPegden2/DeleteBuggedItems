-- DeleteBuggedItems: Experimental addon for deleting items stuck in bugged bank slots
-- Author: Glenn Pegden (Tiltriatura of Rage of Ancients on Chamber of Aspects)

local ADDON_NAME = "DeleteBuggedItems"
local LOG_FILE = "DeleteBuggedItems.log"

-- State variables
local BAG, SLOT = nil, nil  -- Will be set when user clicks item
local selectedItemID = nil
local selectedItemLink = nil
local state = 0  -- 0 = idle, 1 = waiting to delete
local addonActive = false
local warningAccepted = false

-- Logging function
local function Log(message)
    local playerName = UnitName("player")
    local realmName = GetRealmName()
    local timestamp = date("%Y-%m-%d %H:%M:%S")
    local logEntry = string.format("[%s] [%s-%s] %s", timestamp, playerName, realmName, message)
    
    -- Print to chat
    print("|cFF00FF00[DeleteBuggedItems]|r " .. message)
    
    -- Append to saved variables (WoW doesn't have direct file I/O, use SavedVariables)
    if not DeleteBuggedItemsDB then
        DeleteBuggedItemsDB = {}
    end
    table.insert(DeleteBuggedItemsDB, logEntry)
end

-- Forward declarations
local ShowWarningDialog
local ShowBankPromptDialog
local ShowItemConfirmationDialog
local BeginDeletionProcess
local CompleteDeletion
local EnableItemClickDetection

-- Create main dialog frame
local function CreateDialog(title, text, onAccept, onDecline, showButtons)
    local dialog = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    dialog:SetSize(550, 380)
    dialog:SetPoint("CENTER")
    dialog:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 }
    })
    dialog:SetFrameStrata("DIALOG")
    
    -- Title
    local titleText = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    titleText:SetPoint("TOP", 0, -20)
    titleText:SetText(title)
    
    -- Message
    local messageText = dialog:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    messageText:SetPoint("TOP", 0, -55)
    messageText:SetPoint("LEFT", 20, 0)
    messageText:SetPoint("RIGHT", -20, 0)
    messageText:SetJustifyH("LEFT")
    messageText:SetJustifyV("TOP")
    messageText:SetSpacing(3)
    messageText:SetText(text)
    
    if showButtons then
        -- Accept button
        local acceptBtn = CreateFrame("Button", nil, dialog, "UIPanelButtonTemplate")
        acceptBtn:SetSize(120, 30)
        acceptBtn:SetPoint("BOTTOM", -65, 20)
        acceptBtn:SetText("Accept")
        acceptBtn:SetScript("OnClick", function()
            dialog:Hide()
            if onAccept then onAccept() end
        end)
        
        -- Decline button
        local declineBtn = CreateFrame("Button", nil, dialog, "UIPanelButtonTemplate")
        declineBtn:SetSize(120, 30)
        declineBtn:SetPoint("BOTTOM", 65, 20)
        declineBtn:SetText("Decline")
        declineBtn:SetScript("OnClick", function()
            dialog:Hide()
            if onDecline then onDecline() end
        end)
    else
        -- OK button
        local okBtn = CreateFrame("Button", nil, dialog, "UIPanelButtonTemplate")
        okBtn:SetSize(120, 30)
        okBtn:SetPoint("BOTTOM", 0, 20)
        okBtn:SetText("OK")
        okBtn:SetScript("OnClick", function()
            dialog:Hide()
            if onAccept then onAccept() end
        end)
    end
    
    return dialog
end

-- Warning dialog
ShowWarningDialog = function()
    Log("Showing experimental warning dialog")
    local warningText = "WARNING: This addon is EXPERIMENTAL and performs PERMANENT item deletion.\n\n" ..
                       "Items deleted CANNOT be recovered.\n\n" ..
                       "Use with EXTREME CAUTION and only on items you are absolutely certain you want to delete.\n\n" ..
                       "IMPORTANT: This addon only works with the default Blizzard bag/bank UI.\n" ..
                       "Please DISABLE any bag addon replacements (e.g., Bagnon, AdiBags) before using.\n" ..
                       "You can re-enable them after the item is deleted.\n\n" ..
                       "Do you accept the risk and wish to continue?"
    
    CreateDialog("DeleteBuggedItems - WARNING", warningText, 
        function()
            warningAccepted = true
            Log("User accepted warning - proceeding")
            EnableItemClickDetection()
            ShowBankPromptDialog()
        end,
        function()
            Log("User declined warning - addon disabled")
            addonActive = false
            print("|cFF00FF00[DeleteBuggedItems]|r Addon disabled. Use /DeleteBuggedItem to start again.")
        end,
        true
    ):Show()
end

-- Container prompt dialog (bags or bank)
local promptDialog = nil

ShowBankPromptDialog = function()
    Log("Prompting user to select item from bags or bank")
    
    -- Create persistent dialog
    promptDialog = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    promptDialog:SetSize(550, 200)
    promptDialog:SetPoint("CENTER")
    promptDialog:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 }
    })
    promptDialog:SetFrameStrata("DIALOG")
    
    -- Title
    local titleText = promptDialog:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    titleText:SetPoint("TOP", 0, -20)
    titleText:SetText("DeleteBuggedItems - Select Item")
    
    -- Message
    local messageText = promptDialog:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    messageText:SetPoint("TOP", 0, -55)
    messageText:SetPoint("LEFT", 20, 0)
    messageText:SetPoint("RIGHT", -20, 0)
    messageText:SetJustifyH("CENTER")
    messageText:SetJustifyV("TOP")
    messageText:SetSpacing(3)
    messageText:SetText("HOVER your mouse over the item you want to delete in your bags or bank,\n" ..
                       "then press the SPACEBAR to capture it.\n\n" ..
                       "The addon will show you the item details for confirmation.")
    
    promptDialog:Show()
    
    -- Create a frame to capture keybinding
    local captureFrame = CreateFrame("Frame", "DeleteBuggedItemsCaptureFrame", UIParent)
    captureFrame:SetPropagateKeyboardInput(true)
    
    captureFrame:SetScript("OnKeyDown", function(self, key)
        if key == "SPACE" then
            self:SetPropagateKeyboardInput(false)
            
            -- Get the tooltip item
            local _, itemLink = GameTooltip:GetItem()
            
            if not itemLink then
                print("|cFF00FF00[DeleteBuggedItems]|r Hover over an item in your bags, then press SPACE.")
                self:SetPropagateKeyboardInput(true)
                return
            end
            
            -- Parse the item link to get itemID
            local itemID = tonumber(itemLink:match("item:(%d+)"))
            
            if not itemID then
                Log("ERROR: Could not parse item link")
                print("|cFF00FF00[DeleteBuggedItems]|r Error parsing item. Try again.")
                self:SetPropagateKeyboardInput(true)
                return
            end
            
            -- Find the item in bags
            local foundBag, foundSlot = nil, nil
            for bag = 0, 12 do
                for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
                    local slotItemID = C_Container.GetContainerItemID(bag, slot)
                    if slotItemID == itemID then
                        foundBag = bag
                        foundSlot = slot
                        break
                    end
                end
                if foundBag then break end
            end
            
            if not foundBag then
                Log("ERROR: Could not find item in bags")
                print("|cFF00FF00[DeleteBuggedItems]|r Error: Item not found in bags. Make sure you're hovering over a bag item.")
                self:SetPropagateKeyboardInput(true)
                return
            end
            
            Log(string.format("Item found: %s in bag %d slot %d", itemLink, foundBag, foundSlot))
            
            -- Hide the prompt dialog
            if promptDialog then
                promptDialog:Hide()
            end
            
            -- Get item details
            local itemName, _, itemQuality, itemLevel = C_Item.GetItemInfo(itemID)
            
            -- Disable the capture frame
            captureFrame:SetScript("OnKeyDown", nil)
            captureFrame:Hide()
            
            if itemName then
                ShowItemConfirmationDialog(itemLink, itemName, itemLevel, itemQuality, foundBag, foundSlot)
            else
                -- Item info not cached, request it and retry
                C_Item.RequestLoadItemDataByID(itemID)
                C_Timer.After(0.5, function()
                    local name, _, quality, lvl = C_Item.GetItemInfo(itemID)
                    if name then
                        ShowItemConfirmationDialog(itemLink, name, lvl, quality, foundBag, foundSlot)
                    else
                        Log("ERROR: Could not retrieve item information")
                        print("|cFF00FF00[DeleteBuggedItems]|r Error: Could not get item details. Try again.")
                    end
                end)
            end
        else
            self:SetPropagateKeyboardInput(true)
        end
    end)
    
    captureFrame:Show()
    captureFrame:EnableKeyboard(true)
end

-- Item confirmation dialog
ShowItemConfirmationDialog = function(itemLink, itemName, itemLevel, itemQuality, bag, slot)
    Log(string.format("Showing confirmation for item: %s (Bag: %d, Slot: %d, iLvl: %s)", 
                     itemName, bag, slot, tostring(itemLevel)))
    
    -- Test if item is actually bugged by attempting pickup
    C_Container.PickupContainerItem(bag, slot)
    local cursorType, cursorInfo1, cursorInfo2 = GetCursorInfo()
    local isBugged = (cursorType == nil and cursorInfo1 == nil and cursorInfo2 == nil)
    
    -- Put item back if we picked it up
    if cursorType then
        C_Container.PickupContainerItem(bag, slot)
    end
    
    Log(string.format("Item bugged status: %s (cursorType=%s)", tostring(isBugged), tostring(cursorType)))
    
    -- Create custom dialog with item display
    local dialog = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    dialog:SetSize(500, isBugged and 400 or 480)
    dialog:SetPoint("CENTER")
    dialog:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 }
    })
    dialog:SetFrameStrata("DIALOG")
    
    -- Title
    local titleText = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    titleText:SetPoint("TOP", 0, -20)
    titleText:SetText("DeleteBuggedItems - CONFIRM DELETION")
    
    -- Get item info
    local itemID = C_Container.GetContainerItemID(bag, slot)
    local _, _, _, _, _, itemType, itemSubType, _, equipLoc, itemTexture = C_Item.GetItemInfo(itemID)
    local qualityColor = ITEM_QUALITY_COLORS[itemQuality or 0]
    
    -- Item icon
    local icon = dialog:CreateTexture(nil, "ARTWORK")
    icon:SetSize(48, 48)
    icon:SetPoint("TOP", 0, -60)
    icon:SetTexture(itemTexture)
    
    -- Item name (colored by quality)
    local nameText = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    nameText:SetPoint("TOP", icon, "BOTTOM", 0, -10)
    nameText:SetText(itemName)
    nameText:SetTextColor(qualityColor.r, qualityColor.g, qualityColor.b)
    
    -- Item details
    local detailsText = dialog:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    detailsText:SetPoint("TOP", nameText, "BOTTOM", 0, -10)
    detailsText:SetWidth(460)
    detailsText:SetJustifyH("CENTER")
    detailsText:SetSpacing(2)
    
    local details = {}
    if itemLevel and itemLevel > 0 then
        table.insert(details, "Item Level " .. itemLevel)
    end
    if itemType then
        table.insert(details, itemType .. (itemSubType and (" - " .. itemSubType) or ""))
    end
    if equipLoc and equipLoc ~= "" then
        table.insert(details, _G[equipLoc] or equipLoc)
    end
    
    detailsText:SetText(table.concat(details, "\n"))
    
    -- Confirmation text
    local confirmText = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    confirmText:SetPoint("TOP", detailsText, "BOTTOM", 0, -20)
    confirmText:SetWidth(460)
    confirmText:SetJustifyH("CENTER")
    confirmText:SetSpacing(3)
    confirmText:SetText(string.format("Location: Bag %d, Slot %d\n\nAre you ABSOLUTELY SURE you want to delete this item?\n\nThis action CANNOT be undone!", bag, slot))
    
    -- Warning text (prominent)
    local warningText = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    warningText:SetPoint("TOP", confirmText, "BOTTOM", 0, -15)
    warningText:SetWidth(460)
    warningText:SetJustifyH("CENTER")
    warningText:SetText("CLOSE ALL BAG/BANK WINDOWS\nBEFORE ACCEPTING OR DELETE WILL FAIL!")
    warningText:SetTextColor(1.0, 0.2, 0.2) -- Bright red
    
    -- Bugged status warning (if item is NOT bugged)
    if not isBugged then
        local bugWarning = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        bugWarning:SetPoint("TOP", warningText, "BOTTOM", 0, -15)
        bugWarning:SetWidth(460)
        bugWarning:SetJustifyH("CENTER")
        bugWarning:SetSpacing(2)
        bugWarning:SetText("WARNING: This item does NOT appear to be bugged!\n" ..
                          "It can probably be deleted normally (right-click → Delete).\n" ..
                          "Only use this addon if normal deletion fails.")
        bugWarning:SetTextColor(1.0, 0.8, 0.0) -- Yellow/orange
    end
    
    -- Accept button
    local acceptBtn = CreateFrame("Button", nil, dialog, "UIPanelButtonTemplate")
    acceptBtn:SetSize(120, 30)
    acceptBtn:SetPoint("BOTTOM", -65, 20)
    acceptBtn:SetText("Accept")
    acceptBtn:SetScript("OnClick", function()
        dialog:Hide()
        Log(string.format("Setting BAG=%d, SLOT=%d", bag, slot))
        BAG = bag
        SLOT = slot
        selectedItemID = C_Container.GetContainerItemID(bag, slot)
        selectedItemLink = itemLink
        Log(string.format("BAG is now: %s, SLOT is now: %s", tostring(BAG), tostring(SLOT)))
        BeginDeletionProcess()
    end)
    
    -- Decline button
    local declineBtn = CreateFrame("Button", nil, dialog, "UIPanelButtonTemplate")
    declineBtn:SetSize(120, 30)
    declineBtn:SetPoint("BOTTOM", 65, 20)
    declineBtn:SetText("Decline")
    declineBtn:SetScript("OnClick", function()
        dialog:Hide()
        Log("User cancelled deletion")
        BAG, SLOT = nil, nil
        selectedItemID = nil
        selectedItemLink = nil
        addonActive = false
        warningAccepted = false
        state = 0
        print("|cFF00FF00[DeleteBuggedItems]|r Deletion cancelled. Use /DeleteBuggedItem to start again.")
    end)
    
    dialog:Show()
end

-- Event frame for bank detection (optional - can work without bank)
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("BANKFRAME_OPENED")
eventFrame:RegisterEvent("BANKFRAME_CLOSED")

local containerClickHandler = nil

-- Enable item click detection when warning is accepted
EnableItemClickDetection = function()
    -- No longer needed - using button-based capture instead
    Log("Item capture will use button-based method")
end

eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "BANKFRAME_OPENED" then
        Log("Bank opened")
    elseif event == "BANKFRAME_CLOSED" then
        Log("Bank closed")
    end
end)

-- Begin the deletion process (CORE LOGIC - DO NOT MODIFY)
BeginDeletionProcess = function()
    Log(string.format("BeginDeletionProcess called - BAG=%s, SLOT=%s, state=%s", tostring(BAG), tostring(SLOT), tostring(state)))
    
    if not BAG or not SLOT then
        Log("ERROR: BAG or SLOT is nil!")
        print("|cFF00FF00[DeleteBuggedItems]|r ERROR: Item location not set. Please try again.")
        return
    end
    
    if state == 0 then
        Log(string.format("Attempting pickup from bag %d slot %d", BAG, SLOT))

        -- CORE DELETION LOGIC START - DO NOT MODIFY
        C_Container.PickupContainerItem(BAG, SLOT)

        local info = GetCursorInfo()
        if not info then
            Log("Pickup FAILED - Item may be bugged or in a protected slot")
            print("|cFF00FF00[DeleteBuggedItems]|r Pickup FAILED. Item may be bugged or in a protected slot.")
            return
        end

        Log("Pickup SUCCESS - User must now click delete button")
        print("|cFF00FF00[DeleteBuggedItems]|r Pickup SUCCESS. Close all bag windows (press ESC or B).")
        print("|cFF00FF00[DeleteBuggedItems]|r Then CLICK THE DELETE BUTTON that will appear.")
        state = 1
        -- CORE DELETION LOGIC END

        -- Create a deletion button that user must physically click
        C_Timer.After(1, function()
            local deleteBtn = CreateFrame("Button", "DeleteBuggedItemsDeleteButton", UIParent, "UIPanelButtonTemplate")
            deleteBtn:SetSize(200, 50)
            deleteBtn:SetPoint("CENTER")
            deleteBtn:SetText("DELETE ITEM NOW")
            deleteBtn:SetFrameStrata("FULLSCREEN_DIALOG")
            
            -- Make it flash to get attention
            UIFrameFlash(deleteBtn, 0.5, 0.5, -1)
            
            deleteBtn:SetScript("OnClick", function(self)
                self:Hide()
                UIFrameFlashStop(self)
                CompleteDeletion()
            end)
            
            deleteBtn:Show()
        end)
    end
end

-- Complete the deletion (CORE LOGIC - DO NOT MODIFY)
CompleteDeletion = function()
    Log(string.format("CompleteDeletion called - BAG=%s, SLOT=%s", tostring(BAG), tostring(SLOT)))
    
    if not BAG or not SLOT then
        Log("ERROR: BAG or SLOT is nil in CompleteDeletion!")
        print("|cFF00FF00[DeleteBuggedItems]|r ERROR: Item location lost. Please restart with /DeleteBuggedItem.")
        state = 0
        return
    end
    
    -- Check if any container frames are still open
    local anyOpen = false
    local openFrames = {}
    
    if BankFrame and BankFrame:IsShown() then
        anyOpen = true
        table.insert(openFrames, "BankFrame")
    end
    if ContainerFrameCombinedBags and ContainerFrameCombinedBags:IsShown() then
        anyOpen = true
        table.insert(openFrames, "ContainerFrameCombinedBags")
    end
    -- Check individual bag frames
    for i = 1, 13 do
        local bagFrame = _G["ContainerFrame"..i]
        if bagFrame and bagFrame:IsShown() then
            anyOpen = true
            table.insert(openFrames, "ContainerFrame"..i)
        end
    end
    
    if anyOpen then
        Log(string.format("Containers still open: %s", table.concat(openFrames, ", ")))
        print("|cFF00FF00[DeleteBuggedItems]|r Bag/bank still open. Close ALL containers (press ESC or B).")
        return
    end

    Log("All containers closed, proceeding with deletion")
    
    -- CORE DELETION LOGIC START - DO NOT MODIFY
    local info = GetCursorInfo()
    if not info then
        Log("ERROR: No item on cursor - Resetting")
        print("|cFF00FF00[DeleteBuggedItems]|r Error: No item on cursor. Resetting.")
        state = 0
        BAG, SLOT = nil, nil
        selectedItemID = nil
        selectedItemLink = nil
        return
    end

    Log(string.format("Deleting item: %s", selectedItemLink or "Unknown"))
    print("|cFF00FF00[DeleteBuggedItems]|r Deleting cursor item...")
    DeleteCursorItem()
    
    -- Save BAG/SLOT for verification before clearing
    local verifyBag, verifySlot = BAG, SLOT
    
    -- Verify deletion
    C_Timer.After(0.5, function()
        local stillExists = C_Container.GetContainerItemID(verifyBag, verifySlot)
        if stillExists then
            Log("Delete FAILED - Item still exists in slot")
            print("|cFF00FF00[DeleteBuggedItems]|r Delete FAILED. The item is still protected.")
        else
            Log("Delete SUCCESS - Item removed from slot")
            print("|cFF00FF00[DeleteBuggedItems]|r Delete SUCCESS! Item has been removed.")
        end
        
        -- Reset addon state to allow new operations
        addonActive = false
        Log("Addon state reset - ready for new operation")
    end)
    -- CORE DELETION LOGIC END

    state = 0
    BAG, SLOT = nil, nil
    selectedItemID = nil
    selectedItemLink = nil
end

-- Slash command registration
SLASH_DELETEBUGGEDITEM1 = "/DeleteBuggedItem"
SlashCmdList["DELETEBUGGEDITEM"] = function(msg)
    Log("Slash command executed")
    
    if addonActive then
        print("|cFF00FF00[DeleteBuggedItems]|r Addon is already active. Complete the current operation first.")
        return
    end
    
    addonActive = true
    warningAccepted = false
    BAG, SLOT = nil, nil
    selectedItemID = nil
    selectedItemLink = nil
    state = 0
    
    ShowWarningDialog()
end

Log("Addon loaded successfully. Use /DeleteBuggedItem to begin.")
