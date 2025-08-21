import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:csv/csv.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:shared_preferences/shared_preferences.dart';

// --- MODELOS DE DATOS ---
class Employee {
  final String employeeId;
  final String name;
  Employee({required this.employeeId, required this.name});
  Map<String, dynamic> toMap() => {'employeeId': employeeId, 'name': name};
}

class CellLayout {
  int id;
  double x, y, width, height;
  CellLayout({required this.id, required this.x, required this.y, required this.width, required this.height});
  Map<String, dynamic> toJson() => {'id': id, 'x': x, 'y': y, 'width': width, 'height': height};
  factory CellLayout.fromJson(Map<String, dynamic> json) => CellLayout(
      id: json['id'], x: json['x'], y: json['y'], width: json['width'], height: json['height']);
}

class Rack {
  final String rackId;
  final String imagePath;
  List<CellLayout> layout;
  Rack({required this.rackId, required this.imagePath, required this.layout});
  Map<String, dynamic> toMap() => {
        'rackId': rackId,
        'imagePath': imagePath,
        'layout': jsonEncode(layout.map((c) => c.toJson()).toList()),
      };
  factory Rack.fromMap(Map<String, dynamic> map) {
    final List<dynamic> layoutData = jsonDecode(map['layout']);
    return Rack(
      rackId: map['rackId'],
      imagePath: map['imagePath'],
      layout: layoutData.map((json) => CellLayout.fromJson(json)).toList(),
    );
  }
}

class InventoryItem {
  int? id;
  final String rackId;
  final int cellIndex;
  String partNumber;
  int quantity;
  String? description;
  InventoryItem(
      {this.id,
      required this.rackId,
      required this.cellIndex,
      required this.partNumber,
      this.quantity = 0,
      this.description});
  Map<String, dynamic> toMap() => {
        'id': id,
        'rackId': rackId,
        'cellIndex': cellIndex,
        'partNumber': partNumber,
        'quantity': quantity
      };
  factory InventoryItem.fromMap(Map<String, dynamic> map) => InventoryItem(
      id: map['id'],
      rackId: map['rackId'],
      cellIndex: map['cellIndex'],
      partNumber: map['partNumber'],
      quantity: map['quantity']);
}

class MasterPart {
  final String partNumber;
  final String description;
  MasterPart({required this.partNumber, required this.description});
  Map<String, dynamic> toMap() => {'partNumber': partNumber, 'description': description};
}

class SearchResultItem {
  final String rackId;
  final int cellIndex;
  final int quantity;
  SearchResultItem({required this.rackId, required this.cellIndex, required this.quantity});
}

// --- SERVICIOS ---
class AuthService {
  static String? currentEmployeeId;
}

class SettingsService {
  static const _editPasswordKey = 'edit_password';
  static const _defaultPassword = '1234';

  static Future<String> getEditPassword() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_editPasswordKey) ?? _defaultPassword;
  }

  static Future<void> setEditPassword(String newPassword) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_editPasswordKey, newPassword);
  }
}

// --- GESTOR DE LA BASE DE DATOS ---
class DatabaseHelper {
  static Database? _database;
  static final DatabaseHelper instance = DatabaseHelper._init();
  DatabaseHelper._init();

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDB('corporate_inventory_v5.db');
    return _database!;
  }

  Future<Database> _initDB(String filePath) async {
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, filePath);
    return await openDatabase(path, version: 1, onCreate: _createDB);
  }

  Future _createDB(Database db, int version) async {
    await db.execute('''
    CREATE TABLE employees (
      employeeId TEXT PRIMARY KEY,
      name TEXT NOT NULL
    )
    ''');
    await db.execute('''
    CREATE TABLE racks (
      rackId TEXT PRIMARY KEY,
      imagePath TEXT NOT NULL,
      layout TEXT NOT NULL
    )
    ''');
    await db.execute('''
    CREATE TABLE items (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      rackId TEXT NOT NULL,
      cellIndex INTEGER NOT NULL,
      partNumber TEXT NOT NULL,
      quantity INTEGER NOT NULL,
      UNIQUE(rackId, cellIndex, partNumber),
      FOREIGN KEY (rackId) REFERENCES racks (rackId) ON DELETE CASCADE
    )
    ''');
    await db.execute('''
    CREATE TABLE transactions (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      rackId TEXT NOT NULL,
      cellIndex INTEGER NOT NULL,
      partNumber TEXT NOT NULL,
      quantityChange INTEGER NOT NULL,
      employeeId TEXT NOT NULL,
      timestamp TEXT NOT NULL
    )
    ''');
    await db.execute('''
    CREATE TABLE master_parts (
      partNumber TEXT PRIMARY KEY,
      description TEXT NOT NULL
    )
    ''');
  }

  Future<Employee?> getEmployee(String employeeId) async {
    final db = await instance.database;
    final result = await db.query('employees', where: 'employeeId = ?', whereArgs: [employeeId]);
    return result.isNotEmpty ? Employee(employeeId: result.first['employeeId'] as String, name: result.first['name'] as String) : null;
  }

  Future<void> createEmployee(Employee employee) async {
    final db = await instance.database;
    await db.insert('employees', employee.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> createRack(Rack rack) async {
    final db = await instance.database;
    await db.insert('racks', rack.toMap(), conflictAlgorithm: ConflictAlgorithm.replace);
  }
  
  Future<void> updateRackLayout(String rackId, List<CellLayout> layout) async {
    final db = await instance.database;
    await db.update(
      'racks',
      {'layout': jsonEncode(layout.map((c) => c.toJson()).toList())},
      where: 'rackId = ?',
      whereArgs: [rackId],
    );
  }

  Future<List<Rack>> getAllRacks() async {
    final db = await instance.database;
    final result = await db.query('racks', orderBy: 'rackId');
    return result.map((map) => Rack.fromMap(map)).toList();
  }

  Future<void> recordTransactionAndUpdateItem(String rackId, int cellIndex, String partNumber, int quantityChange, String employeeId) async {
    final db = await instance.database;
    await db.transaction((txn) async {
      await txn.insert('transactions', {
        'rackId': rackId,
        'cellIndex': cellIndex,
        'partNumber': partNumber,
        'quantityChange': quantityChange,
        'employeeId': employeeId,
        'timestamp': DateTime.now().toIso8601String(),
      });
      final List<Map<String, dynamic>> existingItems = await txn.query(
        'items',
        where: 'rackId = ? AND cellIndex = ? AND partNumber = ?',
        whereArgs: [rackId, cellIndex, partNumber],
      );
      if (existingItems.isNotEmpty) {
        int newQuantity = existingItems.first['quantity'] + quantityChange;
        if (newQuantity > 0) {
          await txn.update('items', {'quantity': newQuantity}, where: 'id = ?', whereArgs: [existingItems.first['id']]);
        } else {
          await txn.delete('items', where: 'id = ?', whereArgs: [existingItems.first['id']]);
        }
      } else if (quantityChange > 0) {
        await txn.insert('items', {'rackId': rackId, 'cellIndex': cellIndex, 'partNumber': partNumber, 'quantity': quantityChange});
      }
    });
  }

  Future<Map<int, List<InventoryItem>>> getItemsForRack(String rackId) async {
    final db = await instance.database;
    final result = await db.query('items', where: 'rackId = ?', whereArgs: [rackId]);
    Map<int, List<InventoryItem>> inventoryMap = {};
    for (var map in result) {
      final item = InventoryItem.fromMap(map);
      item.description = await getPartDescription(item.partNumber);
      if (!inventoryMap.containsKey(item.cellIndex)) {
        inventoryMap[item.cellIndex] = [];
      }
      inventoryMap[item.cellIndex]!.add(item);
    }
    return inventoryMap;
  }

  Future<List<SearchResultItem>> searchPartNumberGlobal(String partNumber) async {
    final db = await instance.database;
    final result = await db.query('items', where: 'partNumber LIKE ?', whereArgs: ['%$partNumber%']);
    return result.map((map) => SearchResultItem(
      rackId: map['rackId'] as String,
      cellIndex: map['cellIndex'] as int,
      quantity: map['quantity'] as int,
    )).toList();
  }

  Future<String?> getPartDescription(String partNumber) async {
    final db = await instance.database;
    final result = await db.query('master_parts', columns: ['description'], where: 'partNumber = ?', whereArgs: [partNumber]);
    return result.isNotEmpty ? result.first['description'] as String? : null;
  }

  Future<int> loadMasterPartsFromCsv(String filePath) async {
    final file = File(filePath);
    final content = await file.readAsString(encoding: utf8);
    final List<List<dynamic>> rows = const CsvToListConverter().convert(content);
    final db = await instance.database;
    final batch = db.batch();
    int count = 0;
    for (var i = 1; i < rows.length; i++) {
      final row = rows[i];
      if (row.length >= 2) {
        batch.insert('master_parts', {'partNumber': row[0].toString(), 'description': row[1].toString()},
            conflictAlgorithm: ConflictAlgorithm.replace);
        count++;
      }
    }
    await batch.commit(noResult: true);
    return count;
  }
}

// --- PUNTO DE ENTRADA DE LA APP ---
void main() {
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Gestor de Inventario Corporativo',
      theme: ThemeData.light(useMaterial3: true).copyWith(
        primaryColor: Colors.indigo,
        scaffoldBackgroundColor: const Color(0xFFF5F7FA),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          elevation: 1,
          titleTextStyle: TextStyle(color: Color(0xFF1A2533), fontSize: 20, fontWeight: FontWeight.bold),
          iconTheme: IconThemeData(color: Color(0xFF1A2533)),
        ),
        cardTheme: const CardThemeData(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: BorderSide(color: Color(0xFFE0E0E0)),
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            foregroundColor: Colors.white,
            backgroundColor: Colors.indigo[700],
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
        ),
      ),
      home: const LoginPage(),
      debugShowCheckedModeBanner: false,
    );
  }
}

// --- PANTALLA DE LOGIN ---
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});
  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _employeeIdController = TextEditingController();
  bool _isLoading = false;

  Future<void> _login() async {
    setState(() { _isLoading = true; });
    final employee = await DatabaseHelper.instance.getEmployee(_employeeIdController.text);
    setState(() { _isLoading = false; });

    if (employee != null) {
      AuthService.currentEmployeeId = employee.employeeId;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (context) => const HomePage()),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: const Text('Número de empleado no encontrado.'), backgroundColor: Colors.red),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Inicio de Sesión', style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 24),
                  TextField(
                    controller: _employeeIdController,
                    decoration: const InputDecoration(labelText: 'Número de Empleado', border: OutlineInputBorder()),
                  ),
                  const SizedBox(height: 24),
                  _isLoading
                      ? const CircularProgressIndicator()
                      : ElevatedButton(
                          onPressed: _login,
                          child: const Text('Ingresar'),
                        ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// --- PANTALLA DE INICIO ---
class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late Future<List<Rack>> _racksFuture;
  List<SearchResultItem>? _searchResults;
  final _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _refreshRacks();
  }

  void _refreshRacks() {
    setState(() {
      _racksFuture = DatabaseHelper.instance.getAllRacks();
    });
  }

  Future<void> _performSearch() async {
    if (_searchController.text.isEmpty) {
      setState(() { _searchResults = null; });
      return;
    }
    final results = await DatabaseHelper.instance.searchPartNumberGlobal(_searchController.text);
    setState(() { _searchResults = results; });
  }

  Future<void> _openRack(Rack rack) async {
    final imageFile = File(rack.imagePath);
    if (await imageFile.exists()) {
      final imageBytes = await imageFile.readAsBytes();
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => InventoryManagerPage(rack: rack, imageBytes: imageBytes),
        ),
      );
      _refreshRacks();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: No se encontró la imagen en ${rack.imagePath}')),
      );
    }
  }

  Future<void> _loadNewRack() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(type: FileType.image);
    if (result != null && result.files.single.path != null) {
      final file = File(result.files.single.path!);
      final rackId = p.basename(file.path);
      final dimensions = await showDialog<Map<String, int>>(
        context: context,
        builder: (context) => const RackDimensionsDialog(),
      );

      if (dimensions != null) {
        List<CellLayout> initialLayout = [];
        int rows = dimensions['rows']!;
        int cols = dimensions['cols']!;
        double cellWidth = 1.0 / cols;
        double cellHeight = 1.0 / rows;
        for (int i = 0; i < rows * cols; i++) {
          initialLayout.add(CellLayout(
            id: i,
            x: (i % cols) * cellWidth,
            y: (i ~/ cols) * cellHeight,
            width: cellWidth,
            height: cellHeight,
          ));
        }
        final newRack = Rack(rackId: rackId, imagePath: file.path, layout: initialLayout);
        await DatabaseHelper.instance.createRack(newRack);
        _openRack(newRack);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Panel Principal'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (context) => const SettingsPage()),
            ),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Bienvenido, Empleado #${AuthService.currentEmployeeId}',
                style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
            const SizedBox(height: 24),
            Row(children: [
              Expanded(
                child: TextField(
                  controller: _searchController,
                  decoration: const InputDecoration(labelText: 'Buscar Número de Parte Global', border: OutlineInputBorder()),
                  onSubmitted: (_) => _performSearch(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(onPressed: _performSearch, icon: const Icon(Icons.search)),
            ]),
            if (_searchResults != null)
              _buildSearchResults(),
            
            const Divider(height: 48),

            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Racks Disponibles', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
                ElevatedButton.icon(
                  onPressed: _loadNewRack,
                  icon: const Icon(Icons.add),
                  label: const Text('Nuevo Rack'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Expanded(
              child: FutureBuilder<List<Rack>>(
                future: _racksFuture,
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (!snapshot.hasData || snapshot.data!.isEmpty) {
                    return const Center(child: Text('No hay racks guardados en el sistema.'));
                  }
                  final racks = snapshot.data!;
                  return ListView.builder(
                    itemCount: racks.length,
                    itemBuilder: (context, index) {
                      final rack = racks[index];
                      return Card(
                        margin: const EdgeInsets.symmetric(vertical: 6),
                        child: ListTile(
                          leading: const Icon(Icons.grid_on, color: Colors.indigo),
                          title: Text(rack.rackId, style: const TextStyle(fontWeight: FontWeight.bold)),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () => _openRack(rack),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchResults() {
    if (_searchResults!.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(16.0),
        child: Text('No se encontraron resultados.'),
      );
    }
    return SizedBox(
      height: 200, // Altura limitada para la lista de resultados
      child: Card(
        margin: const EdgeInsets.only(top: 16),
        child: ListView.builder(
          itemCount: _searchResults!.length,
          itemBuilder: (context, index) {
            final result = _searchResults![index];
            return ListTile(
              title: Text('Rack: ${result.rackId}'),
              subtitle: Text('Celda: #${result.cellIndex + 1}'),
              trailing: Text('Cantidad: ${result.quantity}', style: const TextStyle(fontWeight: FontWeight.bold)),
            );
          },
        ),
      ),
    );
  }
}

// --- PANTALLA DE GESTIÓN DE INVENTARIO ---
class InventoryManagerPage extends StatefulWidget {
  final Rack rack;
  final Uint8List imageBytes;
  const InventoryManagerPage({super.key, required this.rack, required this.imageBytes});
  @override
  State<InventoryManagerPage> createState() => _InventoryManagerPageState();
}

class _InventoryManagerPageState extends State<InventoryManagerPage> {
  Map<int, List<InventoryItem>> _inventory = {};
  bool _isLoading = true;
  bool _isEditingLayout = false;
  late List<CellLayout> _currentLayout;

  @override
  void initState() {
    super.initState();
    _currentLayout = widget.rack.layout.map((l) => CellLayout.fromJson(l.toJson())).toList();
    _loadInventory();
  }

  Future<void> _loadInventory() async {
    setState(() { _isLoading = true; });
    final allItems = await DatabaseHelper.instance.getItemsForRack(widget.rack.rackId);
    setState(() {
      _inventory = allItems;
      _isLoading = false;
    });
  }

  Future<void> _manageCellInventory(int cellIndex) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => CellInventoryDialog(
        cellIndex: cellIndex,
        rackId: widget.rack.rackId,
      ),
    );
    if (result == true) {
      _loadInventory();
    }
  }

  void _toggleEditMode() async {
    if (_isEditingLayout) {
      setState(() => _isEditingLayout = false);
      return;
    }
    final passwordController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Introducir Clave de Edición'),
        content: TextField(controller: passwordController, obscureText: true, decoration: const InputDecoration(hintText: 'Clave')),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancelar')),
          ElevatedButton(onPressed: () async {
            final storedPassword = await SettingsService.getEditPassword();
            if (passwordController.text == storedPassword) {
              Navigator.of(context).pop(true);
            } else {
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: const Text('Clave incorrecta'), backgroundColor: Colors.red));
            }
          }, child: const Text('Confirmar')),
        ],
      ),
    );
    if (confirmed == true) {
      setState(() { _isEditingLayout = true; });
    }
  }

  void _saveLayout() async {
    await DatabaseHelper.instance.updateRackLayout(widget.rack.rackId, _currentLayout);
    setState(() { _isEditingLayout = false; });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: const Text('Plantilla guardada'), backgroundColor: Colors.green));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Gestionando: ${widget.rack.rackId}'),
        actions: [
          if (_isEditingLayout)
            IconButton(icon: const Icon(Icons.save, color: Colors.green), onPressed: _saveLayout, tooltip: 'Guardar Plantilla'),
          IconButton(
            icon: Icon(_isEditingLayout ? Icons.close : Icons.edit_location_alt_outlined),
            onPressed: _toggleEditMode,
            tooltip: _isEditingLayout ? 'Salir del modo edición' : 'Editar Plantilla',
          ),
        ],
      ),
      body: Row(
        children: [
          SizedBox(width: 350, child: _buildControlPanel()),
          const VerticalDivider(width: 1, color: Color(0xFFE0E0E0)),
          Expanded(child: _buildDisplayArea()),
        ],
      ),
    );
  }

  Widget _buildControlPanel() {
    return Container(
      padding: const EdgeInsets.all(24.0),
      color: Colors.white,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("Información del Rack", style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          const Divider(height: 24),
          Text.rich(TextSpan(children: [
            const TextSpan(text: 'ID: ', style: TextStyle(fontWeight: FontWeight.bold)),
            TextSpan(text: widget.rack.rackId),
          ])),
          const SizedBox(height: 16),
          Text.rich(TextSpan(children: [
            const TextSpan(text: 'Celdas: ', style: TextStyle(fontWeight: FontWeight.bold)),
            TextSpan(text: '${widget.rack.layout.length}'),
          ])),
        ],
      ),
    );
  }

  Widget _buildDisplayArea() {
    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Card(
              clipBehavior: Clip.antiAlias,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      Image.memory(widget.imageBytes, fit: BoxFit.cover),
                      ..._currentLayout.map((layout) => _buildDraggableCell(layout, constraints)).toList(),
                    ],
                  );
                },
              ),
            ),
    );
  }

  Widget _buildDraggableCell(CellLayout layout, BoxConstraints constraints) {
    final cellWidth = layout.width * constraints.maxWidth;
    final cellHeight = layout.height * constraints.maxHeight;
    Widget cellContent = Container(
      decoration: BoxDecoration(
        border: Border.all(color: _isEditingLayout ? Colors.red : Colors.indigo, width: _isEditingLayout ? 2 : 1),
        color: Colors.black.withOpacity(0.2),
      ),
      child: _isEditingLayout
          ? const Center(child: Icon(Icons.open_with, color: Colors.white))
          : _buildCellContent(layout.id),
    );
    return Positioned(
      left: layout.x * constraints.maxWidth,
      top: layout.y * constraints.maxHeight,
      width: cellWidth,
      height: cellHeight,
      child: _isEditingLayout
          ? GestureDetector(
              onPanUpdate: (details) {
                setState(() {
                  layout.x += details.delta.dx / constraints.maxWidth;
                  layout.y += details.delta.dy / constraints.maxHeight;
                  layout.x = layout.x.clamp(0.0, 1.0 - layout.width);
                  layout.y = layout.y.clamp(0.0, 1.0 - layout.height);
                });
              },
              child: cellContent,
            )
          : InkWell(
              onTap: () => _manageCellInventory(layout.id),
              child: cellContent,
            ),
    );
  }

  Widget _buildCellContent(int cellIndex) {
    final itemsInCell = _inventory[cellIndex] ?? [];
    final bool isEmpty = itemsInCell.isEmpty;
    return Container(
      color: isEmpty ? Colors.transparent : Colors.indigo.withOpacity(0.2),
      padding: const EdgeInsets.all(4.0),
      child: isEmpty
          ? null
          : SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: itemsInCell.map((item) {
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    margin: const EdgeInsets.only(bottom: 2),
                    decoration: BoxDecoration(
                      color: Colors.black.withOpacity(0.6),
                      borderRadius: BorderRadius.circular(2),
                    ),
                    child: Text(
                      '${item.partNumber} (${item.quantity})',
                      style: const TextStyle(color: Colors.white, fontSize: 10),
                      overflow: TextOverflow.ellipsis,
                    ),
                  );
                }).toList(),
              ),
            ),
    );
  }
}

// --- PANTALLA DE AJUSTES ---
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _isLoading = false;

  Future<void> _importMasterParts() async {
    setState(() { _isLoading = true; });
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['csv'],
      );
      if (result != null && result.files.single.path != null) {
        final count = await DatabaseHelper.instance.loadMasterPartsFromCsv(result.files.single.path!);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('$count registros importados/actualizados en el maestro de partes.'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error al importar el archivo: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      setState(() { _isLoading = false; });
    }
  }

  void _showChangePasswordDialog() {
    showDialog(context: context, builder: (context) => const ChangePasswordDialog());
  }

  void _showAddEmployeeDialog() {
    showDialog(context: context, builder: (context) => const AddEmployeeDialog());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Ajustes')),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: ListView(
          children: [
            const Text('Gestión de Datos Maestros', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
            const SizedBox(height: 16),
            Card(
              child: ListTile(
                leading: const Icon(Icons.upload_file, color: Colors.indigo),
                title: const Text('Importar Maestro de Partes'),
                subtitle: const Text('Carga un archivo CSV (partNumber, description)'),
                trailing: _isLoading ? const CircularProgressIndicator() : const Icon(Icons.chevron_right),
                onTap: _isLoading ? null : _importMasterParts,
              ),
            ),
            const Divider(height: 32),
            const Text('Seguridad', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
            const SizedBox(height: 16),
            Card(
              child: ListTile(
                leading: const Icon(Icons.password, color: Colors.indigo),
                title: const Text('Cambiar Clave de Edición'),
                subtitle: const Text('Modifica la clave para editar plantillas'),
                trailing: const Icon(Icons.chevron_right),
                onTap: _showChangePasswordDialog,
              ),
            ),
            const Divider(height: 32),
            const Text('Gestión de Empleados', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
            const SizedBox(height: 16),
            Card(
              child: ListTile(
                leading: const Icon(Icons.person_add_alt_1, color: Colors.indigo),
                title: const Text('Registrar Nuevo Empleado'),
                subtitle: const Text('Añade un nuevo usuario al sistema'),
                trailing: const Icon(Icons.chevron_right),
                onTap: _showAddEmployeeDialog,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// --- DIÁLOGOS ---
class RackDimensionsDialog extends StatefulWidget {
  const RackDimensionsDialog({super.key});
  @override
  State<RackDimensionsDialog> createState() => _RackDimensionsDialogState();
}

class _RackDimensionsDialogState extends State<RackDimensionsDialog> {
  final _formKey = GlobalKey<FormState>();
  final _rowsController = TextEditingController(text: '3');
  final _colsController = TextEditingController(text: '4');

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Definir Dimensiones del Rack'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _rowsController,
              decoration: const InputDecoration(labelText: 'Número de Filas', border: OutlineInputBorder()),
              keyboardType: TextInputType.number,
              validator: (v) => (v == null || int.tryParse(v) == null || int.parse(v) < 1) ? 'Debe ser > 0' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _colsController,
              decoration: const InputDecoration(labelText: 'Número de Columnas', border: OutlineInputBorder()),
              keyboardType: TextInputType.number,
              validator: (v) => (v == null || int.tryParse(v) == null || int.parse(v) < 1) ? 'Debe ser > 0' : null,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancelar')),
        ElevatedButton(
          onPressed: () {
            if (_formKey.currentState!.validate()) {
              Navigator.of(context).pop({
                'rows': int.parse(_rowsController.text),
                'cols': int.parse(_colsController.text),
              });
            }
          },
          child: const Text('Confirmar'),
        ),
      ],
    );
  }
}

class CellInventoryDialog extends StatefulWidget {
  final int cellIndex;
  final String rackId;
  const CellInventoryDialog({super.key, required this.cellIndex, required this.rackId});
  @override
  State<CellInventoryDialog> createState() => _CellInventoryDialogState();
}

class _CellInventoryDialogState extends State<CellInventoryDialog> {
  List<InventoryItem> _items = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _refreshItems();
  }

  Future<void> _refreshItems() async {
    setState(() { _isLoading = true; });
    final data = await DatabaseHelper.instance.getItemsForRack(widget.rackId);
    setState(() {
      _items = data[widget.cellIndex] ?? [];
      _isLoading = false;
    });
  }

  Future<void> _showTransactionDialog({InventoryItem? item}) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => TransactionDialog(
        rackId: widget.rackId,
        cellIndex: widget.cellIndex,
        item: item,
      ),
    );
    if (result == true) {
      _refreshItems();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Gestionar Espacio #${widget.cellIndex + 1}'),
      content: SizedBox(
        width: 500,
        height: 400,
        child: Column(
          children: [
            ElevatedButton.icon(
              onPressed: () => _showTransactionDialog(),
              icon: const Icon(Icons.add_box_outlined),
              label: const Text('Registrar Nueva Entrada'),
            ),
            const Divider(height: 24),
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _items.isEmpty
                      ? const Center(child: Text('Este espacio está vacío.'))
                      : ListView.builder(
                          itemCount: _items.length,
                          itemBuilder: (context, index) {
                            final item = _items[index];
                            return Card(
                              margin: const EdgeInsets.symmetric(vertical: 4),
                              child: ListTile(
                                title: Text(item.partNumber, style: const TextStyle(fontWeight: FontWeight.bold)),
                                subtitle: Text(item.description ?? 'Sin descripción'),
                                leading: CircleAvatar(child: Text(item.quantity.toString())),
                                onTap: () => _showTransactionDialog(item: item),
                              ),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
      actions: [
        ElevatedButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Cerrar'),
        ),
      ],
    );
  }
}

class TransactionDialog extends StatefulWidget {
  final String rackId;
  final int cellIndex;
  final InventoryItem? item;
  const TransactionDialog({super.key, required this.rackId, required this.cellIndex, this.item});
  @override
  State<TransactionDialog> createState() => _TransactionDialogState();
}

class _TransactionDialogState extends State<TransactionDialog> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _partNumberController;
  final _quantityController = TextEditingController(text: '1');
  bool _isEntrada = true;

  @override
  void initState() {
    super.initState();
    _partNumberController = TextEditingController(text: widget.item?.partNumber ?? '');
  }

  Future<void> _submitTransaction() async {
    if (_formKey.currentState!.validate()) {
      final quantity = int.parse(_quantityController.text);
      final quantityChange = _isEntrada ? quantity : -quantity;
      await DatabaseHelper.instance.recordTransactionAndUpdateItem(
        widget.rackId,
        widget.cellIndex,
        _partNumberController.text,
        quantityChange,
        AuthService.currentEmployeeId!,
      );
      Navigator.of(context).pop(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.item == null ? 'Registrar Nueva Entrada' : 'Registrar Movimiento'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _partNumberController,
              readOnly: widget.item != null,
              decoration: const InputDecoration(labelText: 'Número de Parte', border: OutlineInputBorder()),
              validator: (v) => (v == null || v.isEmpty) ? 'Campo requerido' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _quantityController,
              decoration: const InputDecoration(labelText: 'Cantidad', border: OutlineInputBorder()),
              keyboardType: TextInputType.number,
              validator: (v) => (v == null || int.tryParse(v) == null || int.parse(v) < 1) ? 'Debe ser > 0' : null,
            ),
            if (widget.item != null) ...[
              const SizedBox(height: 16),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: true, label: Text('Entrada'), icon: Icon(Icons.add)),
                  ButtonSegment(value: false, label: Text('Salida'), icon: Icon(Icons.remove)),
                ],
                selected: {_isEntrada},
                onSelectionChanged: (newSelection) {
                  setState(() { _isEntrada = newSelection.first; });
                },
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancelar')),
        ElevatedButton(onPressed: _submitTransaction, child: const Text('Confirmar')),
      ],
    );
  }
}

class ChangePasswordDialog extends StatefulWidget {
  const ChangePasswordDialog({super.key});
  @override
  State<ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<ChangePasswordDialog> {
  final _formKey = GlobalKey<FormState>();
  final _currentPasswordController = TextEditingController();
  final _newPasswordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  Future<void> _changePassword() async {
    if (_formKey.currentState!.validate()) {
      final currentPassword = await SettingsService.getEditPassword();
      if (_currentPasswordController.text != currentPassword) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: const Text('La clave actual es incorrecta.'), backgroundColor: Colors.red));
        return;
      }
      await SettingsService.setEditPassword(_newPasswordController.text);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: const Text('Clave actualizada con éxito.'), backgroundColor: Colors.green));
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Cambiar Clave de Edición'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _currentPasswordController,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Clave Actual', border: OutlineInputBorder()),
              validator: (v) => (v == null || v.isEmpty) ? 'Campo requerido' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _newPasswordController,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Nueva Clave', border: OutlineInputBorder()),
              validator: (v) => (v == null || v.isEmpty) ? 'Campo requerido' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _confirmPasswordController,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Confirmar Nueva Clave', border: OutlineInputBorder()),
              validator: (v) {
                if (v == null || v.isEmpty) return 'Campo requerido';
                if (v != _newPasswordController.text) return 'Las claves no coinciden';
                return null;
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancelar')),
        ElevatedButton(onPressed: _changePassword, child: const Text('Guardar')),
      ],
    );
  }
}

class AddEmployeeDialog extends StatefulWidget {
  const AddEmployeeDialog({super.key});
  @override
  State<AddEmployeeDialog> createState() => _AddEmployeeDialogState();
}

class _AddEmployeeDialogState extends State<AddEmployeeDialog> {
  final _formKey = GlobalKey<FormState>();
  final _employeeIdController = TextEditingController();
  final _nameController = TextEditingController();

  Future<void> _addEmployee() async {
    if (_formKey.currentState!.validate()) {
      final newEmployee = Employee(
        employeeId: _employeeIdController.text,
        name: _nameController.text,
      );
      await DatabaseHelper.instance.createEmployee(newEmployee);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Empleado "${newEmployee.name}" registrado.'), backgroundColor: Colors.green),
      );
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Registrar Nuevo Empleado'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _employeeIdController,
              decoration: const InputDecoration(labelText: 'Número de Empleado', border: OutlineInputBorder()),
              validator: (v) => (v == null || v.isEmpty) ? 'Campo requerido' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _nameController,
              decoration: const InputDecoration(labelText: 'Nombre Completo', border: OutlineInputBorder()),
              validator: (v) => (v == null || v.isEmpty) ? 'Campo requerido' : null,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancelar')),
        ElevatedButton(onPressed: _addEmployee, child: const Text('Registrar')),
      ],
    );
  }
}
