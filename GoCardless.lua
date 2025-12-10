-- MoneyMoney extension for GoCardless vendor accounts
-- https://github.com/lukasbestle/moneymoney-gocardless
--
---------------------------------------------------------
--
-- MIT License
--
-- Copyright (c) 2023 Lukas Bestle
--
-- Permission is hereby granted, free of charge, to any person obtaining a copy
-- of this software and associated documentation files (the "Software"), to deal
-- in the Software without restriction, including without limitation the rights
-- to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
-- copies of the Software, and to permit persons to whom the Software is
-- furnished to do so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in all
-- copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
-- SOFTWARE.

WebBanking({
    version = 1.02,
    url = "https://api.gocardless.com/",
    services = { "GoCardless" },
    description = string.format(MM.localizeText("Get balance and transactions for %s"), "GoCardless"),
})

local connection = Connection()

-- define local variables and functions
---@type string, table, string
local email, objectCache, password = nil, {}, nil
local apiRequest, buildQuery, buildNegativeTransaction, buildTransaction, getCollection, getObject, isBooked, localizeText, login, parseDate

-----------------------------------------------------------

---**Checks if this extension can request from a specified bank**
---
---@param protocol protocol Protocol of the bank gateway
---@param bankCode string Bank code or service name
---@return boolean | string # `true` or the URL to the online banking entry page if the extension supports the bank, `false` otherwise
function SupportsBank(protocol, bankCode)
    return protocol == ProtocolWebBanking and bankCode == "GoCardless"
end

---**Performs the login to the backend with 2FA**
---
---If the method returns a `LoginChallenge` object on the first call,
---it is called a second time with `step=2`.
---
---@param protocol protocol Protocol of the bank gateway
---@param bankCode string Bank code or service name
---@param step integer Step `1` or `2` of the 2FA
---@param credentials string[] Username and password on `step=1`, the challenge response on `step=2`
---@param interactive boolean If MoneyMoney is running in the foreground
---@return LoginChallenge | LoginFailed | string | nil # 2FA challenge or optional error message
function InitializeSession2(protocol, bankCode, step, credentials, interactive)
    if step == 1 then
        -- if we already have an access token, check if it is still active by
        -- requesting an empty list, which fails when using an outdated or invalid token
        if
            LocalStorage.token ~= nil
            and pcall(apiRequest, "GET", "creditors?created_at[gt]=2999-12-31T00:00:00Z") == true
        then
            -- no login needed
            return nil
        end

        -- no active token, authenticate with email and password;
        -- also keep the credentials in variables for the second step
        email = credentials[1]
        password = credentials[2]
        return login({ email = email, password = password })
    end

    -- authenticate with the provided 2FA code
    return login({ email = email, password = password, otp_code = credentials[1] })
end

---**Returns a list of accounts that can be refreshed with this extension**
---
---@param knownAccounts Account[] List of accounts that are already known via FinTS/HBCI
---@return NewAccount[] | string # List of accounts that can be requsted with web scraping or error message
function ListAccounts(knownAccounts)
    local creditor = getObject("creditor", LocalStorage.creditor)

    return {
        {
            accountNumber = creditor.id,
            currency = creditor.fx_payout_currency,
            name = "GoCardless",
            portfolio = false,
            owner = creditor.name,
            type = AccountTypeOther,
        },
    }
end

---**Refreshes the balance and transaction of an account**
---
---@param account Account Account that is being refreshed
---@param since timestamp | nil POSIX timestamp of the oldest transaction to return or `nil` for portfolios
---@return AccountResults | string # Web scraping results or error message
function RefreshAccount(account, since)
    -- convert the since timestamp into ISO 8601 (yyyy-mm-ddThh:mm:ssZ)
    local sinceDate = os.date("!%F", since)
    local sinceDatetime = os.date("!%FT%TZ", since)

    -- collect the balances for all currencies that are in use for the creditor;
    -- ensure that there is only one pending balance for each currency by
    -- collecting pending balances in an intermediary variable
    local confirmedBalances, pendingBalances, pendingBalancesPerCurrency = {}, {}, {}
    for balance in getCollection("balances", { creditor = account.accountNumber }) do
        if balance.balance_type == "pending_payments_submitted" then
            pendingBalancesPerCurrency[balance.currency] =
                (pendingBalancesPerCurrency[balance.currency] or 0) +
                (balance.amount and (balance.amount / 100) or 0)
        elseif balance.balance_type == "confirmed_funds" then
            table.insert(confirmedBalances, { balance.amount and (balance.amount / 100) or 0, balance.currency })
        elseif balance.balance_type == "pending_payouts" then
            -- subtract the pending payout from the pending balance
            pendingBalancesPerCurrency[balance.currency] =
                (pendingBalancesPerCurrency[balance.currency] or 0) -
                (balance.amount and (balance.amount / 100) or 0)
        else
            print("Ignoring unknown balance type '" .. balance.balance_type .. "")
        end
    end
    for currency, amount in pairs(pendingBalancesPerCurrency) do
        table.insert(pendingBalances, { amount, currency })
    end

    -- collect all payments with MoneyMoney booking date since the requested timestamp
    local transactions = {}
    for payment in getCollection("payments", { creditor = account.accountNumber, ["charge_date[gte]"] = sinceDate }) do
        -- only include payments that will be paid out or that are countered with a negative booking
        if payment.status ~= "cancelled" and payment.status ~= "customer_approval_denied" then
            table.insert(transactions, buildTransaction("payment", payment))
        end
    end

    -- collect all refunds with MoneyMoney booking date since the requested timestamp
    for refund in getCollection("refunds", { ["created_at[gte]"] = sinceDatetime }) do
        -- direct access to the mandate is only possible for refunds outside of payments
        local mandate, payment
        if refund.links.mandate ~= nil then
            mandate = getObject("mandate", refund.links.mandate)
        else
            payment = getObject("payment", refund.links.payment)
            mandate = getObject("mandate", payment.links.mandate)
        end

        -- only include refunds of the correct creditor that will be paid out or that are countered with a negative booking;
        -- filtering by creditor is not possible with the refunds API route, so we need to filter here afterwards
        if mandate.links.creditor == account.accountNumber and refund.status ~= "cancelled" then
            table.insert(transactions, buildTransaction("refund", refund))
        end
    end

    -- collect all payouts with MoneyMoney booking date since the requested timestamp
    for payout in getCollection("payouts", { creditor = account.accountNumber, ["created_at[gte]"] = sinceDatetime }) do
        table.insert(transactions, buildTransaction("payout", payout))

        -- separate transaction for the deducted fees for separate reporting
        table.insert(transactions, {
            amount = -payout.deducted_fees / 100,
            booked = isBooked("payout", payout.status),
            bookingDate = parseDate(payout.created_at),
            bookingText = localizeText("Fees", "Gebühren"),
            currency = payout.currency,
            name = "GoCardless",
            primanotaNumber = payout.id,
            purpose = localizeText("Deducted fees", "Abgezogene Gebühren"),
        })
    end

    -- collect all subsequent reversal events (failures, chargebacks) as negative bookings;
    -- queries are ordered so that later queries can override results of prior ones
    local queries = {
        { resource_type = "payments", include = "payment", action = "failed" },
        { resource_type = "payments", include = "payment", action = "charged_back" },
        { resource_type = "payments", include = "payment", action = "chargeback_settled" },
        { resource_type = "refunds", include = "refund", action = "failed" },
        { resource_type = "refunds", include = "refund", action = "funds_returned" },
    }

    local reversalTransactions = {}
    for _, query in ipairs(queries) do
        -- datetime filter applies to all queries (avoids code duplication above)
        query["created_at[gte]"] = sinceDatetime

        for event in getCollection("events", query) do
            -- retrieve all relevant objects
            local resourceType = event.resource_type:sub(1, -2)
            local object = getObject(resourceType, event.links[resourceType])
            local mandate
            if object.links.mandate ~= nil then
                mandate = getObject("mandate", object.links.mandate)
            else
                -- extra step needed for refunds based on payments because
                -- the mandate is not directly linked from the refund
                local payment = getObject("payment", object.links.payment)
                mandate = getObject("mandate", payment.links.mandate)
            end

            -- ensure that the event belongs to the correct creditor
            -- (API doesn't allow filtering by creditor and resource type at the same time)
            if mandate.links.creditor == account.accountNumber then
                -- failed payments can be retried and can still succeed later,
                -- but a retry will generate another payment transaction in MoneyMoney,
                -- so the failure transaction is immediately marked as booked
                if resourceType == "payment" and event.action == "failed" then
                    local transaction = buildNegativeTransaction("payment", event, object)
                    transaction.booked = true
                    transaction.bookingText = localizeText("Failed", "Fehlgeschlagene")
                        .. " "
                        .. transaction.bookingText
                        .. " ("
                        .. event.details.reason_code
                        .. ")"
                    transaction.purpose = localizeText("Failed Payment", "Fehlgeschlagene Zahlung")
                        .. " ("
                        .. event.details.description
                        .. "): "
                        .. transaction.purpose

                    -- directly add transaction to the list as there
                    -- can be multiple failures for each payment
                    table.insert(transactions, transaction)
                end

                -- chargebacks of payments can be cancelled by the customer bank,
                -- so they are only marked as booked when they have settled;
                -- a cancellation will lead to the negative booking being omitted
                if
                    resourceType == "payment"
                    and (event.action == "charged_back" or event.action == "chargeback_settled")
                    and object.status ~= "confirmed"
                    and object.status ~= "paid_out"
                then
                    -- for settled events we need the previous chargeback event for its metadata
                    local originalEvent = event
                    if event.action == "chargeback_settled" then
                        -- get the first item from the iterator
                        local iterator, state = getCollection("events", {
                            action = "charged_back",
                            payment = object.id,
                        })
                        originalEvent = iterator(state)
                            or error(
                                localizeText(
                                    "Could not retrieve original event for charged back payment " .. object.id,
                                    "Konnte ursprüngliches Ereignis für rückbelastete Zahlung "
                                        .. object.id
                                        .. " nicht abrufen"
                                )
                            )
                    end

                    local transaction = buildNegativeTransaction("payment", event, object)
                    transaction.booked = event.action == "chargeback_settled"
                    transaction.bookingText = localizeText("Charged back", "Rückbelastete")
                        .. " "
                        .. transaction.bookingText
                        .. " ("
                        .. originalEvent.details.reason_code
                        .. ")"
                    transaction.purpose = localizeText("Chargeback", "Rückbelastete Zahlung")
                        .. " ("
                        .. originalEvent.details.description
                        .. "): "
                        .. transaction.purpose

                    reversalTransactions[object.id] = transaction
                end

                -- bounced refunds are marked as booked when the funds have been returned
                if resourceType == "refund" and (event.action == "failed" or event.action == "funds_returned") then
                    local transaction = buildNegativeTransaction("refund", event, object)
                    transaction.booked = event.action == "funds_returned"
                    transaction.bookingText = localizeText("Failed Refund", "Fehlgeschlagene Erstattung")
                    transaction.purpose = localizeText("Failed ", "Fehlgeschlagene ") .. transaction.purpose

                    reversalTransactions[object.id] = transaction
                end
            end
        end
    end

    -- push all reversal transactions into the main transaction list (without keys)
    for _, transaction in pairs(reversalTransactions) do
        table.insert(transactions, transaction)
    end

    return {
        balances = confirmedBalances,
        pendingBalances = pendingBalances,
        transactions = transactions,
    }
end

---**Performs the logout from the backend**
---
---@return string? error Optional error message
function EndSession()
    -- don't perform a logout as the token is cached
end

-----------------------------------------------------------

---**Performs a REST API request to the GoCardless API**
---
---@param method "GET"|"POST"|"PUT"|"PATCH"|"DELETE"
---@param path string
---@param postContent? table Data to send as JSON
---@param fullError? boolean If set to `true`, a full error object is thrown
---@return table response
---@return table headers
function apiRequest(method, path, postContent, fullError)
    local requestHeaders = {
        Accept = "application/json",
        ["GoCardless-Version"] = "2015-07-06",
    }

    if LocalStorage.token ~= nil then
        requestHeaders.Authorization = "Bearer " .. LocalStorage.token
    end

    -- only send a POST body if content was passed
    local postContentJson, postContentType
    if postContent ~= nil then
        postContentJson = JSON():set(postContent):json()
        postContentType = "application/json"
    end

    local json, _, _, _, headers =
        connection:request(method, url .. path, postContentJson, postContentType, requestHeaders)

    local response = JSON(json):dictionary()

    if response.error then
        -- sleep and retry if we hit a rate limit
        if response.error.type == "rate-limit-exceeded" then
            local resetTime = parseDate(headers["ratelimit-reset"], "RFC 5322")
            print("Hit rate limit, sleeping until " .. os.date("%c", resetTime))

            MM.sleep(resetTime - os.time() + 1)

            print("Retrying request...")
            return apiRequest(method, path, postContent, fullError)
        end

        -- other error, throw it to the calling code;
        -- only throw the whole error if the calling code can handle it
        if fullError == true then
            error(response.error)
        end

        -- otherwise throw the message for the UI;
        -- report the line of the effective API caller
        -- (skipping this function and the getCollection or getObject function)
        print("Info: " .. response.error.documentation_url)
        error(response.error.message .. " (" .. response.error.type .. ")", 3)
    end

    return response, headers
end

---**Concats a table of params into a HTTP query string**
---
---@param params table|nil
---@return string query
function buildQuery(params)
    -- empty query when there are no params
    if params == nil or next(params) == nil then
        return ""
    end

    local query = ""
    for key, value in pairs(params) do
        -- append an ampersand before each subsequent param
        if query ~= "" then
            query = query .. "&"
        end

        query = query .. key .. "=" .. value
    end

    return "?" .. query
end

---**Builds a negative MoneyMoney transaction from an API object**
---
---@param class "payment"|"refund"|"payout"
---@param event table API object of the reversal event
---@param object table API object of the provided class
---@return Transaction transaction
function buildNegativeTransaction(class, event, object)
    local transaction = buildTransaction(class, object)

    transaction.amount = -transaction.amount
    transaction.bookingDate = parseDate(event.created_at --[[@as string]])

    return transaction
end

---**Builds a MoneyMoney transaction from an API object**
---
---@param class "payment"|"refund"|"payout"
---@param object table API object of the provided class
---@return Transaction transaction
function buildTransaction(class, object)
    -- gather common sub-objects
    local payment, mandate, bankAccount
    if class == "payment" or class == "refund" then
        -- in refunds, direct access to the mandate is only possible
        -- for refunds outside of payments
        if object.links.mandate ~= nil then
            mandate = getObject("mandate", object.links.mandate)
        else
            payment = getObject("payment", object.links.payment)
            mandate = getObject("mandate", payment.links.mandate)
        end

        -- catch errors with the full error object because we
        -- need to handle the case of removed customer data
        local success
        success, bankAccount = pcall(getObject, "customer_bank_account", mandate.links.customer_bank_account, true)
        if success == false then
            -- bankAccount contains the error object

            if bankAccount.errors[1].reason == "customer_data_removed" then
                -- no customer data available in the API
                bankAccount = nil
            else
                -- general error, throw it to the UI as normal
                print("Info: " .. bankAccount.documentation_url)
                error(bankAccount.message .. " (" .. bankAccount.type .. ")")
            end
        end
    else
        bankAccount = getObject("creditor_bank_account", object.links.creditor_bank_account)
    end

    -- build the base transactions with fields that all classes share
    local transaction = {
        amount = object.amount / 100,
        booked = isBooked(class, object.status),
        bookingDate = parseDate(object.created_at),
        currency = object.currency,
        endToEndReference = object.reference,
        primanotaNumber = object.id,
    }

    if bankAccount ~= nil then
        transaction.accountNumber = "····"
            .. bankAccount.account_number_ending
            .. " ("
            .. bankAccount.bank_name
            .. ")"
        transaction.name = bankAccount.account_holder_name
    elseif class ~= "payout" then
        transaction.name = "(" .. localizeText("Removed customer", "Entfernte Kund:in") .. ")"
    end

    -- extend the base transaction with class-specific fields
    if class == "payment" then
        local schemeLabels = {
            ach = "ACH",
            autogiro = "Autogiro",
            bacs = "Bacs",
            becs = "BECS",
            becs_nz = "BECS NZ",
            betalingsservice = "Betalingsservice",
            faster_payments = "Faster Payments",
            pad = "PAD",
            pay_to = "PayTo",
            sepa_core = localizeText("SEPA Core", "SEPA-Basislastschrift"),
        }

        transaction.bookingDate = parseDate(object.charge_date)
        transaction.bookingText = (schemeLabels[mandate.scheme] or mandate.scheme)
            .. localizeText(" Payment", "-Zahlung")
        transaction.mandateReference = mandate.reference
        transaction.purpose = object.description
    end

    if class == "refund" then
        -- refunds are debit transactions
        transaction.amount = -transaction.amount

        transaction.bookingText = localizeText("Refund", "Erstattung")

        -- also include the payment ID when the refund is based on a payment
        if payment ~= nil then
            transaction.primanotaNumber = transaction.primanotaNumber .. "/" .. payment.id
        end

        transaction.purpose = localizeText("Refund", "Erstattung")
        if payment ~= nil and payment.description ~= nil then
            transaction.purpose = transaction.purpose .. ": " .. payment.description
        end
    end

    if class == "payout" then
        -- payouts are debit transactions
        transaction.amount = -transaction.amount

        transaction.bookingText = localizeText("Payout", "Auszahlung")
        transaction.purpose = localizeText("Payout", "Auszahlung")
        transaction.valueDate = parseDate(object.arrival_date)
    end

    return transaction
end

---**Returns an iterator for all items of a paginated API collection**
---
---@param class string Plural object type (slug of the collection in the API)
---@param params? table Optional query params
---@return fun(state: table): table|nil iterator
---@return table state
function getCollection(class, params)
    -- default value if not passed
    params = params or {}

    local function iterator(state)
        -- request the endpoint if we don't have any data or
        -- if we have run out of paginated data but have a next page
        if state.data == nil or (state.index >= #state.data and state.params.after ~= nil) then
            local response = apiRequest("GET", class .. buildQuery(state.params))
            state.data = response[class]

            -- cache all included linked objects we may need later
            for linkedClass, linkedObjects in pairs(response.linked or {}) do
                for _, linkedObject in ipairs(linkedObjects) do
                    objectCache[linkedClass .. "/" .. linkedObject.id] = linkedObject
                end
            end

            -- reset the index as we have a new list
            state.index = 0

            -- remember the cursor for the next pagination request
            state.params.after = response.meta and response.meta.cursors.after or nil
        end

        -- no more results, stop the loop
        if state.index >= #state.data then
            return nil
        end

        -- return the next object from the collection
        state.index = state.index + 1
        return state.data[state.index]
    end

    local state = { params = params, data = nil, index = 0 }
    return iterator, state
end

---**Returns a single object from the API**
---
---@param class string Singular object type (slug of the collection in the API)
---@param id string ID of the object to return
---@param fullError? boolean If set to `true`, a full error object is thrown
---@return table object
function getObject(class, id, fullError)
    local path = class .. "s/" .. id

    -- return object from cache if already requested before
    if objectCache[path] ~= nil then
        return objectCache[path]
    end

    local response = apiRequest("GET", path, nil, fullError)
    objectCache[path] = response[class .. "s"]
    return objectCache[path]
end

---**Determines if an API object is to be displayed as booked in the MoneyMoney transaction list**
---
---@param class "payment"|"payout"|"refund" Singular object type (slug of the collection in the API)
---@param status string Object's `status` value from the API
---@return boolean
function isBooked(class, status)
    if class == "payment" then
        -- a failed or charged back payment is booked but receives a negative booking
        return status == "confirmed" or status == "paid_out" or status == "failed" or status == "charged_back"
    elseif class == "payout" then
        -- a bounced payout can be retried and should not be displayed as booked in this state
        return status == "paid"
    elseif class == "refund" then
        -- a bounced or returned refund is booked but receives a negative booking
        return status == "submitted" or status == "paid" or status == "bounced" or status == "funds_returned"
    else
        error("Invalid API class " .. class, 2)
    end
end

---**Returns the string in the current UI language**
---
---@param en string English text
---@param de string German text
---@return string text
function localizeText(en, de)
    return MM.language == "de" and de or en
end

---**Performs the login to the GoCardless API**
---
---@param credentials { email: string, password: string, otp_code?: string }
---@return LoginChallenge | LoginFailed | string | nil # 2FA challenge or optional error message
function login(credentials)
    -- try to request a temporary access token; use `pcall()` to handle API errors
    local status, response = pcall(apiRequest, "POST", "temporary_access_tokens", {
        temporary_access_tokens = {
            email = credentials.email,
            password = credentials.password,
            otp_code = credentials.otp_code,

            -- always request a long-active token as we will cache it
            trust_device = true,
        },
    }, true)

    -- handle auth errors
    if status == false then
        -- invalid credentials
        if response.errors[1].reason == "unauthorized" then
            return LoginFailed
        end

        -- account with enabled 2FA, ask the user for the TOTP/SMS code
        if response.errors[1].reason == "auth_factor_required" then
            local factorType = response.errors[1].metadata.factor_type:upper()
            local number = ""
            if factorType == "SMS" then
                number = localizeText(
                    " (phone number ending " .. response.errors[1].metadata.phone_number_ending .. ")",
                    " (Telefonnummer endet auf " .. response.errors[1].metadata.phone_number_ending .. ")"
                )
            end

            return {
                title = MM.localizeText("Two-Factor Authentication"),
                challenge = localizeText(
                    "Please enter your " .. factorType .. " code" .. number .. ".",
                    "Bitte gebe deinen " .. factorType .. "-Code ein" .. number .. "."
                ),
                label = MM.localizeText("6-digit code"),
            }
        end

        -- wrong 2FA code, ask the user again
        if
            response.errors[1].reason == "two_factor_auth_invalid_otp_totp_code"
            or response.errors[1].reason == "two_factor_auth_invalid_otp_sms_code"
        then
            return {
                title = MM.localizeText("Two-Factor Authentication"),
                challenge = localizeText(
                    "Invalid code. Please try again.",
                    "Ungültiger Code. Bitte versuche es erneut."
                ),
                label = MM.localizeText("6-digit code"),
            }
        end

        -- other error, return full error
        print("Info: " .. response.documentation_url)
        return string.format(
            MM.localizeText("The web server %s responded with the error message:\n»%s«\nPlease try again later."),
            "api.gocardless.com",
            response.message .. " (" .. response.type .. ")"
        )
    end

    -- cache the temporary auth token and creditor for future requests
    LocalStorage.token = response.temporary_access_tokens.token
    LocalStorage.creditor = response.temporary_access_tokens.links.creditor

    -- no error, success
    return nil
end

---**Parses an ISO 8601 or RFC 5322 date to a timestamp**
---
---@param date string|nil
---@param format? "ISO 8601"|"RFC 5322" Defaults to ISO 8601
---@return integer|nil timestamp
---@overload fun(date: string, format?: "ISO 8601"|"RFC 5322"): integer
function parseDate(date, format)
    format = format or "ISO 8601"

    if date == nil then
        return nil
    end

    -- parse the date string into its parts
    local year, month, day, hour, min, sec
    if format == "RFC 5322" then
        local monthNames = {
            Jan = 1,
            Feb = 2,
            Mar = 3,
            Apr = 4,
            May = 5,
            Jun = 6,
            Jul = 7,
            Aug = 8,
            Sep = 9,
            Oct = 10,
            Nov = 11,
            Dec = 12,
        }
        day, month, year, hour, min, sec = date:match("%a+, (%d+) (%a+) (%d+) (%d+):(%d+):(%d+) GMT")
        month = monthNames[month]
    else
        year, month, day, hour, min, sec = date:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)%.%d+Z")

        -- try to parse just a date if the first regex wasn't successful
        if year == nil then
            year, month, day = date:match("(%d+)-(%d+)-(%d+)")
        end
    end

    if year == nil then
        print("Failed to parse date '" .. date .. "' in " .. format .. " format")
        error(localizeText("Could not parse a date value", "Konnte einen Datumswert nicht verarbeiten"))
    end

    -- calculate the offset of the current timezone from UTC;
    -- we need to compare to UTC without additionally correcting
    -- for daylight saving time!
    local utc = os.date("!*t") --[[@as osdate]]
    utc.isdst = nil
    local offset = os.time() - os.time(utc)

    -- convert to a POSIX timestamp
    return offset
        + os.time({
            day = day,
            month = month,
            year = year,
            hour = hour,
            min = min,
            sec = sec,
        })
end
