export const SERVICES = ['Website', 'E-commerce', 'Maintenance'];

export function normalizeText(value) {
  return typeof value === 'string' ? value.trim().replace(/\s+/g, ' ') : '';
}

export function validateInquiry(input) {
  const data = {
    name: normalizeText(input.name),
    email: normalizeText(input.email).toLowerCase(),
    service: normalizeText(input.service),
    message: normalizeText(input.message),
  };
  const errors = [];
  if (data.name.length < 2 || data.name.length > 100) errors.push('Name must contain 2–100 characters.');
  if (data.email.length > 254 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(data.email)) errors.push('Enter a valid email address.');
  if (!SERVICES.includes(data.service)) errors.push('Choose one of the listed services.');
  if (data.message.length < 10 || data.message.length > 4000) errors.push('Message must contain 10–4,000 characters.');
  return { valid: errors.length === 0, data, errors };
}

export function validateUpdate(input) {
  const data = { inquiry_id: normalizeText(input.inquiry_id), status: normalizeText(input.status) };
  const errors = [];
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(data.inquiry_id)) errors.push('Enter a valid inquiry reference.');
  if (!['contacted', 'closed'].includes(data.status)) errors.push('Choose contacted or closed.');
  return { valid: errors.length === 0, data, errors };
}

export function classifyDelivery(response, now = Date.now()) {
  const status = Number(response.statusCode || 0);
  const body = response.body || {};
  if (status >= 200 && status < 300 && typeof body.id === 'string' && body.id.length > 0) {
    return { success: true, provider_id: body.id, transient: false, error: null, retry_after_seconds: 0 };
  }
  const transient = status === 0 || status === 408 || status === 429 || status >= 500 ||
    (status === 409 && body.name === 'concurrent_idempotent_requests');
  const retryHeader = response.headers?.['retry-after'];
  let retryAfter = 0;
  if (retryHeader !== undefined) {
    const numeric = Number(retryHeader);
    retryAfter = Number.isFinite(numeric) ? numeric : Math.ceil((Date.parse(retryHeader) - now) / 1000);
  }
  return {
    success: false,
    provider_id: null,
    transient,
    // Store a classification, not provider responses containing personal data.
    error: status ? 'Resend HTTP ' + status + (body.name ? ' (' + String(body.name).slice(0,100) + ')' : '') : 'Transport error; delivery outcome unknown',
    retry_after_seconds: Number.isFinite(retryAfter) ? Math.max(0, Math.min(86400, Math.ceil(retryAfter))) : 0,
  };
}
