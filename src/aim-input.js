// Screen-space aim stays independent of camera yaw and pitch, including at the edges.
export const AIM_LIMIT = 0.9;
const finite = value => Number.isFinite(value) ? value : 0;
const clamp = value => Math.max(-AIM_LIMIT, Math.min(AIM_LIMIT, finite(value)));

export function moveAim(aim, dx, dy, width, height, sensitivity = 1) {
  const speed = Math.max(0, finite(sensitivity));
  return {
    x: clamp(finite(aim.x) + finite(dx) * 2 / Math.max(1, finite(width)) * speed),
    y: clamp(finite(aim.y) - finite(dy) * 2 / Math.max(1, finite(height)) * speed),
  };
}

export function pointAim(clientX, clientY, rect) {
  return {
    x: clamp((finite(clientX) - rect.left) / Math.max(1, rect.width) * 2 - 1),
    y: clamp(1 - (finite(clientY) - rect.top) / Math.max(1, rect.height) * 2),
  };
}
