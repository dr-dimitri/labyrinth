import Foundation
import simd

/// Two optional cross-connections. The existing southern gaps remain open;
/// neither outer route nor a mission anchor depends on breaking these panels.
public enum BlacksiteBreach {
    public static let definitions: [MapBreachDefinition] = [
        MapBreachDefinition(ownerObstacleID: 25,kind: .lightPanel,visibility: .opaque,frameObstacleIDs: [26,27,28]),
        MapBreachDefinition(ownerObstacleID: 29,kind: .glass,visibility: .clear,frameObstacleIDs: [30,31,32])
    ]
    public static let obstacles: [Obstacle] = {
        let terrain = TerrainProfile.battlefield
        var result: [Obstacle] = []
        for (id,kind,x,z,north,south) in [(25,ObstacleKind.accessPanel,Float(-15.8),Float(1.5),Float(-5.5),Float(6.1)),
                                         (29,.glass,Float(20),Float(-18),Float(-20),Float(-14.2))] {
            let doorFloor = terrain.height(x: x,z: z)
            result.append(Obstacle(id: id,kind: kind,position: SIMD3(x,0,z),size: SIMD3(0.18,2.8,2.2)))
            for (offset,low,high) in [(1,north,z-1.1),(2,z+1.1,south)] {
                let centerZ = (low+high)*0.5
                var minimum = terrain.height(x: x,z: centerZ), maximum = minimum
                // One-time conservative grounding of the entire narrow wall.
                // No renderer-only supports or floating foundations are needed.
                for sampleZ in Int(floor(low))...Int(ceil(high)) {
                    for sampleX in Int(floor(x-0.16))...Int(ceil(x+0.16)) {
                        let height = terrain.height(x: Float(sampleX),z: Float(sampleZ))
                        minimum = min(minimum,height); maximum = max(maximum,height)
                    }
                }
                let top = max(doorFloor+3.05,maximum+2.8)
                var frame = Obstacle(id: id+offset,kind: .container,
                    position: SIMD3(x,minimum-terrain.height(x: x,z: centerZ),centerZ),size: SIMD3(0.32,top-minimum,high-low))
                frame.health = .infinity; result.append(frame)
            }
            var header = Obstacle(id: id+3,kind: .container,position: SIMD3(x,2.8,z),size: SIMD3(0.32,0.25,2.2))
            header.health = .infinity; result.append(header)
        }
        return result
    }()
}
