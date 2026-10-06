// Comparing a config the panel wants against the one a device reported. Kept in
// one place because the field markers and the "applied / pending" badge must
// agree: a badge saying "applied" next to a marked field would be a bug.

// Reads a dotted path; a missing branch reads as unset rather than throwing,
// since the device omits defaulted proto fields entirely.
export function readPath(root, path) {
  let node = root;
  for (const key of path.split('.')) {
    if (node === null || node === undefined || typeof node !== 'object') return undefined;
    node = node[key];
  }
  return node;
}

function isEmpty(value) {
  return (
    value === undefined ||
    value === null ||
    value === false ||
    value === '' ||
    value === 0 ||
    (Array.isArray(value) && value.length === 0)
  );
}

// Proto3 JSON drops fields sitting at their default, so an absent field and an
// explicit default mean the same thing. Treating them as equal is what keeps
// the marker off fields nobody touched.
export function sameValue(a, b) {
  if (a === b) return true;
  if (isEmpty(a) && isEmpty(b)) return true;
  if (typeof a === 'object' && typeof b === 'object' && a && b) {
    return stableJson(a) === stableJson(b);
  }
  return sameEnumName(a, b);
}

// Значения, которые устройство заполняет само при инициализации. Панель за них не
// отвечает: устройство подставит своё сразу после пуша, и сравнение сохранённого
// конфига с тем, что вернуло устройство, разойдётся навсегда - часик будет висеть
// при каждом обновлении и ничего не будет значить. Ключи названы по имени, а не
// по пути, потому что список профилей сравнивается целиком, а не по полям;
// вложенные поля с тем же именем (xray.settings.localProxyUsername и подобные)
// под правило не попадают.
const DEVICE_OWNED_KEYS = new Set([
  'type',
  'browserFingerprint',
  'vkTurnEndpoint',
  'proxyUsername',
  'proxyPassword',
  'proxyAuthEnabled',
]);

// То же самое по путям - для полей верхнего уровня, которые панель сравнивает
// напрямую, а не внутри разобранного объекта.
const DEVICE_OWNED_PATHS = new Set(['type']);

function stripDeviceOwned(value) {
  if (value === null || typeof value !== 'object') return value;
  if (Array.isArray(value)) return value.map(stripDeviceOwned);
  const out = {};
  for (const key of Object.keys(value).sort()) {
    if (DEVICE_OWNED_KEYS.has(key)) continue;
    out[key] = stripDeviceOwned(value[key]);
  }
  return out;
}

// Сравнение для отметок "ожидает применения". Отличается от sameValue только
// тем, что не считает разницей значения, которыми владеет устройство.
// buildPatch продолжает пользоваться sameValue: правка админа должна доезжать
// и когда он меняет как раз такое поле.
export function sameAppliedValue(a, b) {
  if (a === b) return true;
  if (isEmpty(a) && isEmpty(b)) return true;
  if (typeof a === 'object' && typeof b === 'object' && a && b) {
    return stableJson(stripDeviceOwned(a)) === stableJson(stripDeviceOwned(b));
  }
  return sameEnumName(a, b);
}

// Панель отвечает только за значения, которые реально заданы. В proto3 нет
// presence, поэтому пустое desired неотличимо от "не задано" и читается как
// "панель молчит". Так админский переключатель, который он снял, не даёт вечного
// часика, а push всё равно довозит правку: buildPatch умеет влять поле,
// которого в сохранённом конфиге ещё нет.
export function panelClaims(desired, path) {
  if (DEVICE_OWNED_PATHS.has(path)) return false;
  // Скалярные поля приходят сю путём, а не разобранным объектом, поэтому имя
  // последнего сегмента проверяем отдельно. Вложенные имена вида
  // xray.settings.localProxyUsername под правило не попадают - совпадение точное.
  const parts = path.split('.');
  if (DEVICE_OWNED_KEYS.has(parts[parts.length - 1])) return false;
  return !isEmpty(readPath(desired, path));
}

// Один источник правды для маркера поля и бейджа секции: они обязаны считать
// одно и то же множество полей, иначе рядом будут "применено" и часик.
export function pendingAt(desired, reported, path) {
  if (!desired || !reported) return null;
  if (!panelClaims(desired, path)) return null;
  const d = readPath(desired, path);
  const r = readPath(reported, path);
  if (sameAppliedValue(d, r)) return null;
  return { text: describeValue(r, d) };
}

// A proto enum travels as CONSTANT_NAME, but the same setting can reach the panel
// under its bare suffix ("SYSTEM" beside "THEME_MODE_SYSTEM"), and the two must not
// read as a pending change. Only all-caps underscore tokens match this way, so
// case-sensitive data such as a VK link or a package name stays untouched.
function sameEnumName(a, b) {
  if (!isEnumToken(a) || !isEnumToken(b)) return false;
  return a === b || a.endsWith('_' + b) || b.endsWith('_' + a);
}

function isEnumToken(value) {
  return typeof value === 'string' && /^[A-Z][A-Z0-9_]*$/.test(value);
}

// Key order is not meaningful in the JSON we get back, so sort before comparing.
export function stableJson(value) {
  if (value === null || typeof value !== 'object') return JSON.stringify(value);
  if (Array.isArray(value)) return '[' + value.map(stableJson).join(',') + ']';
  const keys = Object.keys(value)
    .filter((k) => !isEmpty(value[k]))
    .sort();
  return '{' + keys.map((k) => JSON.stringify(k) + ':' + stableJson(value[k])).join(',') + '}';
}

// `like` is the value on the panel's side, used only to read an absent field in
// the field's own language: proto3 omits a false switch, and telling the admin a
// switch is "не задано" when the device plainly has it off is just confusing.
// Numbers stay "не задано" - an omitted number means the app's default, not 0.
export function describeValue(value, like) {
  if (value === undefined || value === null || value === '') {
    if (typeof like === 'boolean') return 'выключено';
    if (Array.isArray(like)) return 'пусто';
    return 'не задано';
  }
  if (value === true) return 'включено';
  if (value === false) return 'выключено';
  if (Array.isArray(value)) return value.length ? value.join(', ') : 'пусто';
  if (typeof value === 'object') return JSON.stringify(value);
  return String(value);
}

// Every leaf the panel actually specifies, as dotted paths. Arrays count as one
// leaf: their contents are compared whole, the way the form edits them.
function leafPaths(node, prefix = []) {
  if (node === null || typeof node !== 'object' || Array.isArray(node)) {
    return prefix.length ? [prefix.join('.')] : [];
  }
  return Object.keys(node).flatMap((key) => leafPaths(node[key], prefix.concat(key)));
}

// True when every field the panel specified already has that value on the
// device. Deliberately a subset check, not an equality one: the device reports
// its whole config, including settings the panel never manages, so demanding
// equality would leave the badge stuck on "pending" forever. The subset is also
// narrowed to values the panel actually owns - see panelClaims.
export function desiredApplied(desired, reported) {
  if (!desired || !reported) return false;
  return leafPaths(desired)
    .filter((path) => panelClaims(desired, path))
    .every((path) => sameAppliedValue(readPath(desired, path), readPath(reported, path)));
}

// Собирает патч: только те ветки, которые правда разъехались с сохранённым
// конфигом. Целиком конфиг слать нельзя - тогда любое сохранение объявляет
// тронутыми все поля разом, и двое админов дерутся на ровном месте.
export function buildPatch(draft, stored) {
  const patch = {};
  collect(draft || {}, stored || {}, patch);
  return patch;
}

function collect(draft, stored, out) {
  for (const key of Object.keys(draft)) {
    const next = draft[key];
    const was = stored ? stored[key] : undefined;
    if (sameValue(next, was)) continue;
    // Внутрь вложенного лезем вглубь: "тронут весь раздел" - это лишний срач
    if (isPlainObject(next) && isPlainObject(was)) {
      const nested = {};
      collect(next, was, nested);
      if (Object.keys(nested).length > 0) out[key] = nested;
      continue;
    }
    out[key] = next;
  }
  // Стёртое поле тоже правка: иначе снятая галка нихуя не доедет
  for (const key of Object.keys(stored || {})) {
    if (key in draft) continue;
    if (isEmpty(stored[key])) continue;
    out[key] = emptyLike(stored[key]);
  }
}

function isPlainObject(value) {
  return value !== null && typeof value === 'object' && !Array.isArray(value);
}

function emptyLike(value) {
  if (Array.isArray(value)) return [];
  if (isPlainObject(value)) return {};
  if (typeof value === 'boolean') return false;
  if (typeof value === 'number') return 0;
  return '';
}
