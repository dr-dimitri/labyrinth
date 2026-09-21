import test from 'node:test';
import assert from 'node:assert/strict';
import { moveAim, pointAim } from '../src/aim-input.js';

test('mouse and trackpad deltas move the reticle in screen pixels without changing the view', () => {
  const state = { x: 0, y: 0, yaw: 1.2, pitch: -0.2 };
  for (const [width, height] of [[1280,800],[960,720],[1920,1080]]) {
    const aim = moveAim(state,120,-75,width,height);
    assert.ok(Math.abs(aim.x*width/2-120)<1e-9);
    assert.ok(Math.abs(aim.y*height/2-75)<1e-9);
  }
  assert.deepEqual(state,{x:0,y:0,yaw:1.2,pitch:-0.2});
});

test('reticle clamps to screen edges and responds immediately when reversing direction', () => {
  const edge = moveAim({x:0,y:0},1e6,-1e6,960,720);
  assert.deepEqual(edge,{x:.9,y:.9});
  const reversed = moveAim(edge,-10,10,960,720);
  assert.ok(reversed.x < edge.x && reversed.y < edge.y);
  assert.deepEqual(moveAim({x:0,y:0},100,100,1000,1000,.5),{x:.1,y:-.1});
});

test('unlocked cursor maps viewport coordinates including resized or offset canvases', () => {
  const rect = {left:30,top:50,width:1000,height:600};
  assert.deepEqual(pointAim(530,350,rect),{x:0,y:0});
  const point = pointAim(780,200,rect);
  assert.deepEqual(point,{x:.5,y:.5});
  assert.deepEqual(pointAim(-500,3000,rect),{x:-.9,y:-.9});
});
