# VideoCutEditor

Swift Package `VideoCutEditor` + iOS demo app (`Demo/VideoCutEditorDemo.xcodeproj`).

## Package public API

```swift
public struct VideoCut {
    public var startTime: TimeInterval
    public var endTime: TimeInterval
}

let editor = VideoCutViewController(videoURL: videoURL, cuts: cuts)
editor.onExportCompleted = { outputURL in
    // tmp/VideoCutEditor/<UUID>.mp4
}

VideoCutFileManager.remove(outputURL)
VideoCutFileManager.clearTemporaryFiles()
```

## Demo app

Open:
`/home/runner/work/VideoCutEditor/VideoCutEditor/Demo/VideoCutEditorDemo.xcodeproj`

Flow:
- Select Video (PHPicker)
- Open Video Cut Editor
- Done -> export MP4 -> play result with `AVPlayerViewController`
- Clear Temporary Files
