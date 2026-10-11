@description('Monthly budget amount in the billing currency. This is an alert threshold, not a spending cap.')
@minValue(1)
param amount int

@description('Budget name.')
param budgetName string

@description('First day of the month the budget starts (yyyy-MM-01).')
param startDate string

@description('Email addresses notified when thresholds are crossed.')
@minLength(1)
param contactEmails array

resource budget 'Microsoft.Consumption/budgets@2023-11-01' = {
  name: budgetName
  properties: {
    category: 'Cost'
    amount: amount
    timeGrain: 'Monthly'
    timePeriod: {
      startDate: startDate
    }
    notifications: {
      actual80: {
        enabled: true
        operator: 'GreaterThan'
        threshold: 80
        thresholdType: 'Actual'
        contactEmails: contactEmails
      }
      actual100: {
        enabled: true
        operator: 'GreaterThan'
        threshold: 100
        thresholdType: 'Actual'
        contactEmails: contactEmails
      }
      forecast100: {
        enabled: true
        operator: 'GreaterThan'
        threshold: 100
        thresholdType: 'Forecasted'
        contactEmails: contactEmails
      }
    }
  }
}

output budgetResourceId string = budget.id
