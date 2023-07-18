# GoCardless extension for MoneyMoney

This extension for [MoneyMoney](https://moneymoney-app.com/) retrieves the balance and transactions of [GoCardless](https://gocardless.com) vendor accounts.

## How to use

### Installation

1. Download the signed extension file of the [latest release](https://github.com/lukasbestle/moneymoney-gocardless/releases/latest).
2. Open the database directory of MoneyMoney as described on the [MoneyMoney website](https://moneymoney-app.com/extensions/).
3. Place the extension file (`GoCardless.lua`) in the `Extensions` directory of your MoneyMoney database.
4. Add a new account of type "GoCardless". You can log in with your credentials for <https://manage.gocardless.com>. GoCardless accounts with enabled 2FA are supported.

### Manual correction of failed payments

If a payment has failed but was subsequently retried, this extension creates a separate MoneyMoney transaction for each failure and retry. However this history cannot be fully reconstructed from the GoCardless API.

**This means:** After you initially create the GoCardless account in MoneyMoney, check that the transactions are consistent. If you notice missing payment retry transactions, you can manually correct for this in one of two ways:

- Either you delete the previous failure transactions so that you have just one failure transaction per payment (if the payment finally failed) or no failure transaction (if the payment succeeded after the retry).
- Or you manually create a payment transaction before each failure transaction.

**This only has to be done during setup.** Regular operation is unaffected as this extension creates all the necessary transactions if the account is refreshed regularly.
