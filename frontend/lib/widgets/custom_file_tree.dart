import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';

// --- Style Classes (Merged from style.dart) ---

/// Defines customizable styling options for folder elements in the directory tree.
class FolderStyle {
  /// Icon displayed when the folder is closed.
  final dynamic folderClosedicon;

  /// Icon displayed when the folder is opened.
  final dynamic folderOpenedicon;

  /// Text style applied to folder names.
  final TextStyle? folderNameStyle;

  /// Icon used for the "create new folder" action.
  final dynamic iconForCreateFolder;

  /// Icon used for the "create new file" action within a folder.
  final dynamic iconForCreateFile;

  /// Icon used for the "delete folder" action.
  final dynamic iconForDeleteFolder;

  /// Icon for root folder closed state.
  final dynamic rootFolderClosedIcon;

  /// Icon for root folder open state.
  final dynamic rootFolderOpenedIcon;

  /// Gap between items.
  final double itemGap;

  /// Constructs a [FolderStyle] with customizable icons and text styles.
  FolderStyle({
    this.itemGap = 15,
    this.rootFolderClosedIcon = const Icon(Icons.chevron_right_sharp),
    this.rootFolderOpenedIcon = const Icon(Icons.keyboard_arrow_down_sharp),
    this.folderNameStyle = const TextStyle(),
    this.iconForCreateFolder = const Icon(Icons.create_new_folder),
    this.iconForCreateFile = const Icon(
      Icons.note_add, // Replaced FontAwesomeIcons.fileCirclePlus
      size: 20,
    ),
    this.iconForDeleteFolder = const Icon(Icons.delete),
    this.folderClosedicon = const Icon(Icons.folder),
    this.folderOpenedicon = const Icon(Icons.folder_open),
  });
}

/// Defines customizable styling options for file elements in the directory tree.
class FileStyle {
  /// Default file icon.
  /// Applied when no custom icon is provided via fileIconBuilder.
  final dynamic fileIcon;

  /// [TextStyle] for file tile title.
  final TextStyle? fileNameStyle;

  /// Icon for delete button if it is enabled.
  final dynamic iconForDeleteFile;

  /// Constructs a [FileStyle] with customizable icons and text styles.
  FileStyle({
    this.fileNameStyle = const TextStyle(),
    this.fileIcon = const Icon(Icons.insert_drive_file),
    this.iconForDeleteFile = const Icon(Icons.delete),
  });
}

class EditingFieldStyle {
  /// Leading icon/widget displayed while creating new folder.
  final dynamic folderIcon;

  /// Leading icon/widget displayed while creating new file.
  final dynamic fileIcon;

  /// [InputDecoration] for [TextField] which appears while creating new file/folder.
  final InputDecoration textfieldDecoration;

  /// Icon for done button.
  final dynamic doneIcon;

  /// Icon for cancel button.
  final dynamic cancelIcon;

  /// Height of the text field.
  final double textFieldHeight;

  /// Width of the text field.
  final double textFieldWidth;

  /// Cursor color.
  final Color? cursorColor;

  /// Height of the cursor.
  final double cursorHeight;

  /// Width of the cursor.
  final double cursorWidth;

  /// Cursor radius.
  final Radius? cursorRadius;

  /// Text (Cursor) vertical alignment
  final TextAlignVertical? verticalTextAlign;

  /// [TextStyle] for text in the text filed.
  final TextStyle? textStyle;

  ///Custom styling for the [TextField] for creating files/folders.
  EditingFieldStyle({
    this.textFieldHeight = 30,
    this.textFieldWidth = double.infinity,
    this.cursorHeight = 20,
    this.cursorWidth = 2.0,
    this.cursorRadius,
    this.cursorColor,
    this.verticalTextAlign,
    this.textStyle,
    this.textfieldDecoration = const InputDecoration(),
    this.folderIcon = const Icon(Icons.folder),
    this.fileIcon = const Icon(Icons.edit_document),
    this.doneIcon = const Icon(Icons.check),
    this.cancelIcon = const Icon(Icons.close),
  });
}

// --- Logic Classes ---

/// Manages the state of the directory tree, handling folder expansion and file operations.
class DirectoryTreeStateNotifier extends ChangeNotifier {
  ///// Tracks open/close state of folders
  final Map<String, bool> _folderStates = {};

  bool isParentOpen = true;
  String? currentDir;

  /// Path of the new entry being created
  String? newEntryPath;

  /// Flag to determine if new entry is a folder
  bool isFolderCreation = false;

  ///Watches for file system changes
  StreamSubscription<FileSystemEvent>? _directoryWatcher;

  /// Checks if a folder is expanded or collapsed
  bool isUnfolded(String dirPath, String rootPath) => dirPath == rootPath
      ? _folderStates[rootPath] = isParentOpen
      : (_folderStates[dirPath] ?? false);

  /// Toggles folder expansion/collapse state
  void toggleFolder(String dirPath, String rootPath) {
    if (dirPath != rootPath) {
      _folderStates[dirPath] = !(_folderStates[dirPath] ?? false);
    }
    notifyListeners();
  }

  /// Starts the creation process of a new folder or file
  void startCreating(String parentPath, bool folder) {
    newEntryPath = parentPath;
    isFolderCreation = folder;
    notifyListeners();
  }

  /// Stops the creation process and clears the state
  void stopCreating() {
    newEntryPath = null;
    notifyListeners();
  }

  /// Watches the given directory for changes and updates the UI accordingly
  void watchDirectory(String directoryPath) {
    _directoryWatcher?.cancel();
    final dir = Directory(directoryPath);
    if (dir.existsSync()) {
      _directoryWatcher = dir.watch(recursive: true).listen((event) {
        if (event is FileSystemCreateEvent ||
            event is FileSystemModifyEvent ||
            event is FileSystemDeleteEvent) {
          notifyListeners();
        }
      });
    }
  }
}

/// A provider that supplies [DirectoryTreeStateNotifier] to its descendants in the widget tree.
class DirectoryTreeStateProvider
    extends InheritedNotifier<DirectoryTreeStateNotifier> {
  /// Constructs a [DirectoryTreeStateProvider] with the given notifier and child widget.
  const DirectoryTreeStateProvider({
    super.key,
    required DirectoryTreeStateNotifier super.notifier,
    required super.child,
  });

  /// Accesses the [DirectoryTreeStateNotifier] in the widget tree.
  static DirectoryTreeStateNotifier of(BuildContext context) {
    final provider = context
        .dependOnInheritedWidgetOfExactType<DirectoryTreeStateProvider>();
    assert(provider != null, 'No DirectoryTreeStateProvider found in context');
    return provider!.notifier!;
  }
}

/// A widget that displays a foldable directory tree, showing files and subdirectories.
class FoldableDirectoryTree extends StatefulWidget {
  final String rootPath;
  final bool enableCreateFolderOption, enableCreateFileOption;
  final bool enableDeleteFolderOption, enableDeleteFileOption;
  final FolderStyle? folderStyle;
  final FileStyle? fileStyle;
  final EditingFieldStyle? editingFieldStyle;
  final void Function(File, TapDownDetails)? onFileTap;
  final void Function(File, TapDownDetails)? onFileSecondaryTap;
  final void Function(Directory, TapDownDetails)? onDirTap;
  final void Function(Directory, TapDownDetails)? onDirSecondaryTap;
  final List<Widget>? folderActions;
  final List<Widget>? fileActions;
  final Widget Function(String fileExtension)? fileIconBuilder;
  
  // Custom properties
  final String? selectedPath;
  final Set<String>? updatedPaths;

  const FoldableDirectoryTree({
    super.key,
    required this.rootPath,
    this.onFileTap,
    this.onFileSecondaryTap,
    this.onDirTap,
    this.onDirSecondaryTap,
    this.folderStyle,
    this.fileStyle,
    this.folderActions,
    this.fileActions,
    this.editingFieldStyle,
    this.enableCreateFileOption = false,
    this.enableCreateFolderOption = false,
    this.enableDeleteFileOption = false,
    this.enableDeleteFolderOption = false,
    this.fileIconBuilder,
    this.selectedPath,
    this.updatedPaths,
  });

  @override
  State<FoldableDirectoryTree> createState() => _FoldableDirectoryTreeState();
}

/// Recursively builds the directory tree for a given [directory] using [stateNotifier] to manage folder states.
class _FoldableDirectoryTreeState extends State<FoldableDirectoryTree> {
  Widget _buildDirectoryTree(
    Directory directory,
    DirectoryTreeStateNotifier stateNotifier,
  ) {
    final entries = directory.listSync();
    entries.sort((a, b) {
      if (a is Directory && b is File) return -1;
      if (a is File && b is Directory) return 1;
      return a.path.compareTo(b.path);
    });

    final bool isSelected = widget.selectedPath != null && 
        (path.equals(widget.selectedPath!, directory.path) || widget.selectedPath == directory.path);
    
    final bool hasUpdate = widget.updatedPaths != null && 
        widget.updatedPaths!.contains(directory.path);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTapDown: (details) {
            if (widget.onDirTap != null) {
              widget.onDirTap!(directory, details);
            }
          },
          onSecondaryTapDown: (details) {
            if (widget.onDirSecondaryTap != null) {
              widget.onDirSecondaryTap!(directory, details);
            }
          },
          onTap: () {
            stateNotifier.toggleFolder(directory.path, widget.rootPath);
          },
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: Container(
              color: isSelected ? Colors.blue.withOpacity(0.1) : Colors.transparent,
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  directory.path != widget.rootPath
                      ? (stateNotifier.isUnfolded(directory.path, widget.rootPath)
                            ? widget.folderStyle?.folderOpenedicon ??
                                  FolderStyle().folderOpenedicon
                            : widget.folderStyle?.folderClosedicon ??
                                  FolderStyle().folderClosedicon)
                      : stateNotifier.isParentOpen
                      ? widget.folderStyle?.rootFolderOpenedIcon ??
                            FolderStyle().rootFolderOpenedIcon
                      : widget.folderStyle?.rootFolderClosedIcon ??
                            FolderStyle().rootFolderClosedIcon,
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      path.basename(directory.path),
                      overflow: TextOverflow.ellipsis,
                      style:
                          widget.folderStyle?.folderNameStyle ??
                          FolderStyle().folderNameStyle,
                    ),
                  ),
                  if (hasUpdate) ...[
                     const SizedBox(width: 8),
                     const Icon(Icons.circle, color: Colors.red, size: 8),
                  ],
                  SizedBox(
                    width: widget.folderStyle?.itemGap ?? FolderStyle().itemGap,
                  ),
                  if (widget.enableCreateFileOption &&
                      stateNotifier.isUnfolded(directory.path, widget.rootPath) &&
                      stateNotifier.currentDir == directory.path)
                    IconButton(
                      onPressed: () =>
                          stateNotifier.startCreating(directory.path, false),
                      icon:
                          widget.folderStyle?.iconForCreateFile ??
                          FolderStyle().iconForCreateFile,
                    ),
                  if (widget.enableCreateFolderOption &&
                      stateNotifier.isUnfolded(directory.path, widget.rootPath) &&
                      stateNotifier.currentDir == directory.path)
                    IconButton(
                      onPressed: () =>
                          stateNotifier.startCreating(directory.path, true),
                      icon:
                          widget.folderStyle?.iconForCreateFolder ??
                          FolderStyle().iconForCreateFolder,
                    ),
                  if (widget.enableDeleteFolderOption &&
                      stateNotifier.isUnfolded(directory.path, widget.rootPath) &&
                      stateNotifier.currentDir == directory.path)
                    IconButton(
                      onPressed: () {
                        Directory(directory.path).delete(recursive: true);
                        setState(() {});
                      },
                      icon: const Icon(Icons.delete),
                    ),
                  ...widget.folderActions ?? [],
                ],
              ),
            ),
          ),
        ),
        if (stateNotifier.isUnfolded(directory.path, widget.rootPath))
          Padding(
            padding: const EdgeInsets.only(left: 16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ...entries.map((entry) {
                  if (entry is Directory) {
                    return _buildDirectoryTree(
                      Directory(entry.path),
                      stateNotifier,
                    );
                  } else if (entry is File) {
                    return _buildFileItem(entry);
                  }
                  return const SizedBox.shrink();
                }),
                if (stateNotifier.newEntryPath == directory.path)
                  _buildNewEntryField(directory, stateNotifier),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildNewEntryField(
    Directory parent,
    DirectoryTreeStateNotifier stateNotifier,
  ) {
    TextEditingController controller = TextEditingController();
    return Row(
      children: [
        stateNotifier.isFolderCreation
            ? widget.editingFieldStyle?.folderIcon ??
                  EditingFieldStyle().folderIcon
            : widget.editingFieldStyle?.fileIcon ??
                  EditingFieldStyle().fileIcon,
        const SizedBox(width: 8),
        Expanded(
          child: SizedBox(
            height: widget.editingFieldStyle?.textFieldHeight,
            width: widget.editingFieldStyle?.textFieldWidth,
            child: TextField(
              style: widget.editingFieldStyle?.textStyle,
              textAlignVertical: widget.editingFieldStyle?.verticalTextAlign,
              cursorRadius: widget.editingFieldStyle?.cursorRadius,
              cursorWidth: widget.editingFieldStyle?.cursorWidth ?? 2.0,
              cursorHeight: widget.editingFieldStyle?.cursorHeight,
              cursorColor: widget.editingFieldStyle?.cursorColor,
              controller: controller,
              autofocus: true,
              decoration:
                  widget.editingFieldStyle?.textfieldDecoration ??
                  EditingFieldStyle().textfieldDecoration,
              onSubmitted: (value) {
                if (value.trim().isNotEmpty) {
                  final newPath = path.join(parent.path, value.trim());
                  if (stateNotifier.isFolderCreation) {
                    Directory(newPath).createSync();
                  } else {
                    File(newPath).createSync();
                  }
                }
                stateNotifier.stopCreating();
              },
            ),
          ),
        ),
        IconButton(
          icon:
              widget.editingFieldStyle?.doneIcon ??
              EditingFieldStyle().doneIcon,
          onPressed: () {
            if (controller.text.trim().isNotEmpty) {
              final newPath = path.join(parent.path, controller.text.trim());
              if (stateNotifier.isFolderCreation) {
                Directory(newPath).createSync();
              } else {
                File(newPath).createSync();
              }
            }
            stateNotifier.stopCreating();
          },
        ),
        IconButton(
          icon:
              widget.editingFieldStyle?.cancelIcon ??
              EditingFieldStyle().cancelIcon,
          onPressed: () {
            stateNotifier.stopCreating();
          },
        ),
      ],
    );
  }

  /// Builds the widget for a single file item.
  Widget _buildFileItem(File file) {
    final extension = path.extension(file.path).toLowerCase();
    final customIcon = widget.fileIconBuilder != null
        ? widget.fileIconBuilder!(extension)
        : widget.fileStyle?.fileIcon ?? FileStyle().fileIcon;
    
    final bool isSelected = widget.selectedPath != null && 
        (path.equals(widget.selectedPath!, file.path) || widget.selectedPath == file.path);
    
    final bool hasUpdate = widget.updatedPaths != null && 
        widget.updatedPaths!.contains(file.path);

    return GestureDetector(
      onTapDown: (details) {
        if (widget.onFileTap != null) {
          widget.onFileTap!(file, details);
        }
      },
      onSecondaryTapDown: (details) {
        if (widget.onFileSecondaryTap != null) {
          widget.onFileSecondaryTap!(file, details);
        }
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
           color: isSelected ? Colors.blue.withOpacity(0.1) : Colors.transparent,
           padding: const EdgeInsets.symmetric(vertical: 2),
           child: Row(
            children: [
              customIcon,
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  path.basename(file.path),
                  overflow: TextOverflow.ellipsis,
                  style:
                      widget.fileStyle?.fileNameStyle ?? FileStyle().fileNameStyle,
                ),
              ),
              if (hasUpdate) ...[
                 const SizedBox(width: 8),
                 const Icon(Icons.circle, color: Colors.red, size: 8),
              ],
              ...widget.fileActions ?? [],
              if (widget.enableDeleteFileOption)
                IconButton(
                  onPressed: () {
                    file.deleteSync(recursive: true);
                    setState(() {});
                  },
                  icon:
                      widget.fileStyle?.iconForDeleteFile ??
                      FileStyle().iconForDeleteFile,
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final stateNotifier = DirectoryTreeStateProvider.of(context);
    stateNotifier.watchDirectory(widget.rootPath);
    final rootDirectory = Directory(widget.rootPath);

    if (!rootDirectory.existsSync()) {
      return const Center(child: Text('Directory does not exist'));
    }

    return SingleChildScrollView(
      child: _buildDirectoryTree(rootDirectory, stateNotifier),
    );
  }
}
