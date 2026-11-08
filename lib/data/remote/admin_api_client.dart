import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/auth/auth_providers.dart';
import 'api_client.dart';

class AdminStats {
  const AdminStats({
    required this.totalUsers,
    required this.totalCustomers,
    required this.totalPharmacists,
    required this.totalMedicines,
    required this.totalOrders,
    required this.pendingPrescriptions,
    required this.lowStockCount,
    required this.totalRevenue,
  });

  final int totalUsers;
  final int totalCustomers;
  final int totalPharmacists;
  final int totalMedicines;
  final int totalOrders;
  final int pendingPrescriptions;
  final int lowStockCount;
  final num totalRevenue;

  factory AdminStats.fromJson(Map<String, dynamic> json) => AdminStats(
    totalUsers: _int(json['totalUsers']),
    totalCustomers: _int(json['totalCustomers']),
    totalPharmacists: _int(json['totalPharmacists']),
    totalMedicines: _int(json['totalMedicines']),
    totalOrders: _int(json['totalOrders']),
    pendingPrescriptions: _int(json['pendingPrescriptions']),
    lowStockCount: _int(json['lowStockCount']),
    totalRevenue: json['totalRevenue'] is num
        ? json['totalRevenue'] as num
        : num.tryParse('${json['totalRevenue']}') ?? 0,
  );
}

class AdminUser {
  const AdminUser({
    required this.id,
    required this.name,
    required this.email,
    required this.role,
    required this.isActive,
    required this.createdAt,
    required this.orderCount,
  });

  final String id;
  final String name;
  final String email;
  final String role;
  final bool isActive;
  final DateTime createdAt;
  final int orderCount;

  factory AdminUser.fromJson(Map<String, dynamic> json) => AdminUser(
    id: json['id'] as String,
    name: (json['name'] as String?) ?? '',
    email: (json['email'] as String?) ?? '',
    role: (json['role'] as String?) ?? 'customer',
    isActive: json['isActive'] as bool? ?? true,
    createdAt: DateTime.parse(json['createdAt'] as String),
    orderCount: _int(json['orderCount']),
  );
}

class AdminMedicine {
  const AdminMedicine({
    required this.id,
    required this.name,
    required this.description,
    required this.genericName,
    required this.categoryId,
    required this.price,
    required this.stockQuantity,
    required this.expiryDate,
    required this.requiresPrescription,
    required this.genericId,
    required this.slug,
    required this.type,
    required this.dosageForm,
    required this.strength,
    required this.manufacturer,
    required this.packageContainer,
    required this.packageSize,
  });

  final String id;
  final String name;
  final String? description;
  final String? genericName;
  final String categoryId;
  final num price;
  final int stockQuantity;
  final DateTime? expiryDate;
  final bool requiresPrescription;
  final int? genericId;
  final String? slug;
  final String? type;
  final String? dosageForm;
  final String? strength;
  final String? manufacturer;
  final String? packageContainer;
  final String? packageSize;

  factory AdminMedicine.fromJson(Map<String, dynamic> json) => AdminMedicine(
    id: json['id'] as String,
    name: (json['name'] as String?) ?? '',
    description: json['description'] as String?,
    genericName: _descriptionPart(json['description'], 0),
    categoryId: (json['categoryId'] as String?) ?? '',
    price: json['price'] is num
        ? json['price'] as num
        : num.tryParse('${json['price']}') ?? 0,
    stockQuantity: _int(json['stockQuantity']),
    expiryDate: json['expiryDate'] == null
        ? null
        : DateTime.tryParse(json['expiryDate'] as String),
    requiresPrescription:
        json['isSensitive'] as bool? ??
        json['requiresPrescription'] as bool? ??
        false,
    genericId: _nullableInt(json['genericId']),
    slug: _nullableString(json['slug']),
    type: _nullableString(json['type']),
    dosageForm: _nullableString(json['dosageForm']),
    strength: _nullableString(json['strength']),
    manufacturer: _nullableString(json['manufacturer']),
    packageContainer: _nullableString(json['packageContainer']),
    packageSize: _nullableString(json['packageSize']),
  );
}

String? _descriptionPart(Object? value, int index) {
  if (value is! String) return null;
  final parts = value.split('|');
  if (index >= parts.length) return null;
  final part = parts[index].trim();
  return part.isEmpty ? null : part;
}

class AdminOrder {
  const AdminOrder({
    required this.id,
    required this.customerName,
    required this.customerEmail,
    required this.totalAmount,
    required this.status,
    required this.paymentStatus,
    required this.createdAt,
  });

  final String id;
  final String customerName;
  final String customerEmail;
  final num totalAmount;
  final String status;
  final String paymentStatus;
  final DateTime createdAt;

  factory AdminOrder.fromJson(Map<String, dynamic> json) => AdminOrder(
    id: '${json['id'] ?? ''}',
    customerName: '${json['customerName'] ?? 'Unknown customer'}',
    customerEmail: '${json['customerEmail'] ?? ''}',
    totalAmount: json['totalAmount'] is num
        ? json['totalAmount'] as num
        : num.tryParse('${json['totalAmount']}') ?? 0,
    status: '${json['status'] ?? ''}',
    paymentStatus: '${json['paymentStatus'] ?? ''}',
    createdAt: DateTime.tryParse('${json['createdAt']}') ?? DateTime.now(),
  );
}

int _int(Object? value) => value is num ? value.toInt() : 0;
int? _nullableInt(Object? value) =>
    value is num ? value.toInt() : int.tryParse('$value');
String? _nullableString(Object? value) =>
    value == null || '$value'.trim().isEmpty ? null : '$value';

class AdminCategory {
  const AdminCategory({required this.id, required this.name});

  final String id;
  final String name;

  factory AdminCategory.fromJson(Map<String, dynamic> json) =>
      AdminCategory(id: '${json['id'] ?? ''}', name: '${json['name'] ?? ''}');
}

class AdminGeneric {
  const AdminGeneric({required this.id, required this.name});

  final int id;
  final String name;

  factory AdminGeneric.fromJson(Map<String, dynamic> json) => AdminGeneric(
    id: _int(json['genericId']),
    name: '${json['genericName'] ?? ''}',
  );
}

class AdminMedicineOptions {
  const AdminMedicineOptions({
    required this.categories,
    required this.generics,
    required this.slugs,
    required this.manufacturers,
  });

  final List<AdminCategory> categories;
  final List<AdminGeneric> generics;
  final List<String> slugs;
  final List<String> manufacturers;
}

class AdminApiException implements Exception {
  const AdminApiException(this.message);

  final String message;

  @override
  String toString() => message;
}

final adminApiClientProvider = Provider<AdminApiClient>(
  (ref) => AdminApiClient(ref.watch(apiClientProvider)),
);

class AdminApiClient {
  AdminApiClient(this._api);

  final ApiClient _api;

  Future<AdminStats> getStats() async {
    try {
      final response = await _api.dio.get<Map<String, dynamic>>('/admin/stats');
      final data = response.data?['data'];
      if (data is! Map<String, dynamic>) {
        throw const AdminApiException(
          'The server sent invalid dashboard data.',
        );
      }
      return AdminStats.fromJson(data);
    } on DioException catch (error) {
      throw AdminApiException(
        ApiClient.serverMessageOf(error) ??
            'Could not load the admin dashboard.',
      );
    }
  }

  Future<List<AdminUser>> listUsers({String? role}) async {
    try {
      final response = await _api.dio.get<Map<String, dynamic>>(
        '/admin/users',
        queryParameters: {'role': ?role},
      );
      final data = response.data?['data'];
      final users = data is Map<String, dynamic> ? data['users'] : data;
      if (users is! List) {
        throw const AdminApiException('The server sent invalid user data.');
      }
      return users
          .whereType<Map<String, dynamic>>()
          .map(AdminUser.fromJson)
          .toList(growable: false);
    } on DioException catch (error) {
      throw AdminApiException(
        ApiClient.serverMessageOf(error) ?? 'Could not load users.',
      );
    }
  }

  Future<AdminUser> setUserActive({
    required String id,
    required bool isActive,
  }) async {
    try {
      final response = await _api.dio.patch<Map<String, dynamic>>(
        '/admin/users/$id/status',
        data: {'isActive': isActive},
      );
      final data = response.data?['data'];
      if (data is! Map<String, dynamic>) {
        throw const AdminApiException('The server sent invalid user data.');
      }
      return AdminUser.fromJson(data);
    } on DioException catch (error) {
      throw AdminApiException(
        ApiClient.serverMessageOf(error) ?? 'Could not update user status.',
      );
    }
  }

  Future<List<AdminMedicine>> listMedicines({String? search}) async {
    try {
      final response = await _api.dio.get<Map<String, dynamic>>(
        '/medicines',
        queryParameters: {'limit': 100, 'search': ?search},
      );
      final data = response.data?['data'];
      final medicines = data is Map<String, dynamic> ? data['medicines'] : data;
      if (medicines is! List) {
        throw const AdminApiException('The server sent invalid medicine data.');
      }

      return medicines
          .whereType<Map<String, dynamic>>()
          .map(AdminMedicine.fromJson)
          .toList(growable: false);
    } on DioException catch (error) {
      throw AdminApiException(
        ApiClient.serverMessageOf(error) ?? 'Could not load medicines.',
      );
    }
  }

  Future<AdminMedicineOptions> getMedicineOptions() async {
    try {
      final response = await _api.dio.get<Map<String, dynamic>>(
        '/admin/medicine-options',
      );
      final data = response.data?['data'];
      if (data is! Map<String, dynamic>) {
        throw const AdminApiException(
          'The server sent invalid medicine options.',
        );
      }
      final categories = data['categories'];
      final generics = data['generics'];
      final slugs = data['slugs'];
      final manufacturers = data['manufacturers'];
      if (categories is! List || slugs is! List || manufacturers is! List) {
        throw const AdminApiException(
          'The server sent invalid medicine options.',
        );
      }
      return AdminMedicineOptions(
        categories: categories
            .whereType<Map<String, dynamic>>()
            .map(AdminCategory.fromJson)
            .toList(growable: false),
        generics: generics is List
            ? generics
                  .whereType<Map<String, dynamic>>()
                  .map(AdminGeneric.fromJson)
                  .where((generic) => generic.id > 0 && generic.name.isNotEmpty)
                  .toList(growable: false)
            : const [],
        slugs: slugs.whereType<String>().toList(growable: false),
        manufacturers: manufacturers.whereType<String>().toList(
          growable: false,
        ),
      );
    } on DioException catch (error) {
      if (error.response?.statusCode == 404) {
        return _getLegacyMedicineOptions();
      }
      throw AdminApiException(
        ApiClient.serverMessageOf(error) ?? 'Could not load medicine options.',
      );
    }
  }

  Future<AdminMedicineOptions> _getLegacyMedicineOptions() async {
    try {
      final categoryResponse = await _api.dio.get<Map<String, dynamic>>(
        '/categories',
      );
      final categoryData = categoryResponse.data?['data'];
      final medicines = await listMedicines();
      final genericOptions = await _getLegacyGenericOptions();
      if (categoryData is! List) {
        throw const AdminApiException(
          'The server sent invalid category options.',
        );
      }
      final slugs =
          medicines
              .map((medicine) => medicine.slug)
              .whereType<String>()
              .where((value) => value.isNotEmpty)
              .toSet()
              .toList()
            ..sort();
      final manufacturers =
          medicines
              .map((medicine) => medicine.manufacturer)
              .whereType<String>()
              .where((value) => value.isNotEmpty)
              .toSet()
              .toList()
            ..sort();
      return AdminMedicineOptions(
        categories: categoryData
            .whereType<Map<String, dynamic>>()
            .map(AdminCategory.fromJson)
            .toList(growable: false),
        generics: genericOptions.isNotEmpty
            ? genericOptions
            : medicines
                  .where((medicine) => medicine.genericId != null)
                  .map(
                    (medicine) => AdminGeneric(
                      id: medicine.genericId!,
                      name: medicine.genericName ?? '',
                    ),
                  )
                  .where((generic) => generic.name.isNotEmpty)
                  .fold<Map<int, AdminGeneric>>(
                    {},
                    (result, generic) => result..[generic.id] = generic,
                  )
                  .values
                  .toList(growable: false),
        slugs: slugs,
        manufacturers: manufacturers,
      );
    } on DioException catch (error) {
      throw AdminApiException(
        ApiClient.serverMessageOf(error) ??
            'Could not load categories and medicine options.',
      );
    }
  }

  Future<List<AdminGeneric>> _getLegacyGenericOptions() async {
    try {
      final response = await _api.dio.get<Map<String, dynamic>>(
        '/generics',
        queryParameters: {'limit': 1000},
      );
      final data = response.data?['data'];
      final generics = data is Map<String, dynamic> ? data['generics'] : data;
      if (generics is! List) return const [];
      return generics
          .whereType<Map<String, dynamic>>()
          .map(AdminGeneric.fromJson)
          .where((generic) => generic.id > 0 && generic.name.isNotEmpty)
          .toList(growable: false);
    } on DioException {
      return const [];
    }
  }

  Future<AdminMedicine> saveMedicine(
    Map<String, dynamic> data, {
    String? id,
  }) async {
    try {
      final response = id == null
          ? await _api.dio.post<Map<String, dynamic>>('/medicines', data: data)
          : await _api.dio.put<Map<String, dynamic>>(
              '/medicines/$id',
              data: data,
            );
      final result = response.data?['data'];
      if (result is! Map<String, dynamic>) {
        throw const AdminApiException('The server sent invalid medicine data.');
      }
      return AdminMedicine.fromJson(result);
    } on DioException catch (error) {
      throw AdminApiException(
        ApiClient.serverMessageOf(error) ?? 'Could not save medicine.',
      );
    }
  }

  Future<void> deleteMedicine(String id) async {
    try {
      await _api.dio.delete<Map<String, dynamic>>('/medicines/$id');
    } on DioException catch (error) {
      throw AdminApiException(
        ApiClient.serverMessageOf(error) ?? 'Could not delete medicine.',
      );
    }
  }

  Future<List<AdminOrder>> listOrders({String? customer}) async {
    try {
      final response = await _api.dio.get<Map<String, dynamic>>(
        '/admin/orders',
        queryParameters: {'search': ?customer},
      );
      final data = response.data?['data'];
      final orders = data is Map<String, dynamic> ? data['orders'] : data;
      if (orders is! List) {
        throw const AdminApiException('The server sent invalid order data.');
      }
      return orders
          .whereType<Map<String, dynamic>>()
          .map(AdminOrder.fromJson)
          .toList(growable: false);
    } on DioException catch (error) {
      throw AdminApiException(
        ApiClient.serverMessageOf(error) ?? 'Could not load orders.',
      );
    }
  }
}
