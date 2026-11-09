function Get-MangaSceneInstruction {
    param([ValidateSet('Source','Indoor','Outdoor','Mixed')][string]$Scene='Source')
    $preserve='SCENE PRESERVATION: Keep the environment and spatial layout exactly as drawn. Flat fills, white space, screentones and speed lines are not scenery to invent. Never add plants, trees, sky, windows, doors or other background objects. Approved character colors do not change the setting.'
    switch($Scene){
        'Indoor' {return $preserve+' INDOOR CONSTRAINT overrides generic landscape palette suggestions: this is an existing interior. Opaque walls remain walls, floors remain floors, doorways and furniture remain in their original places. Use restrained indoor material colors. Do not turn wall gradients or floor areas into blue sky, grass or foliage. Exterior colors are allowed only where an actual source window or open doorway visibly shows the outdoors. Do not invent outdoor views.'}
        'Outdoor' {return $preserve+' OUTDOOR CONSTRAINT: retain the existing exterior setting and only the scenery actually drawn. Do not invent architecture, vegetation or indoor rooms to fill blank areas.'}
        'Mixed' {return $preserve+' MIXED SCENES: determine each panel from its own existing architecture. Keep interiors indoors and exteriors outdoors. Do not carry a background from one panel into another.'}
        default {return $preserve+' Follow the source setting panel by panel. Keep existing wall and floor surfaces as material surfaces; existing windows alone may show visible exterior scenery. Do not assume that a light gradient means sky or that dark screentones mean vegetation.'}
    }
}
