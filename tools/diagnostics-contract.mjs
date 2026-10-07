export function createDiagnosticSettings({ supportedLogCategories, supportedMetricCategories, logCategories = [], metricCategories = [] }) {
  const areCategories = (categories) =>
    Array.isArray(categories) && categories.every((category) => typeof category === 'string' && category.trim() !== '');

  if (!areCategories(supportedLogCategories) || !areCategories(supportedMetricCategories)) {
    throw new TypeError('Supported log and metric categories must be arrays of non-empty strings.');
  }

  if (!areCategories(logCategories) || !areCategories(metricCategories)) {
    throw new TypeError('Requested log and metric categories must be arrays of non-empty strings.');
  }

  if (logCategories.length === 0 && metricCategories.length === 0) {
    throw new Error('At least one supported log or metric category must be requested.');
  }

  if (new Set(logCategories).size !== logCategories.length || new Set(metricCategories).size !== metricCategories.length) {
    throw new Error('Diagnostic category requests must not contain duplicates.');
  }

  const unsupportedLogs = logCategories.filter((category) => !supportedLogCategories.includes(category));
  if (unsupportedLogs.length > 0) {
    throw new Error(`Unsupported log categories: ${unsupportedLogs.join(', ')}`);
  }

  const unsupportedMetrics = metricCategories.filter((category) => !supportedMetricCategories.includes(category));
  if (unsupportedMetrics.length > 0) {
    throw new Error(`Unsupported metric categories: ${unsupportedMetrics.join(', ')}`);
  }

  if (metricCategories.some((category) => category !== 'AllMetrics')) {
    throw new Error('Only the AllMetrics diagnostic metric category is supported by this contract.');
  }

  return {
    logCategories,
    enableAllMetrics: metricCategories.includes('AllMetrics'),
  };
}
