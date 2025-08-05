////
////  FreenectPCL.m
////  GTest
////
////  Created by Dev on 7/14/17.
////  Copyright © 2017 Dev. All rights reserved.
////
//
//#include <opencv2/opencv.hpp>
//
//
//#import "FreenectPCL.h"
////#import "Renderer.h"
//
////------
////Not needed anymore but its importing correctly
////"Error no device found" when running ONI examples
////#include <OpenNI.h>
////------
//#include "viewer.h"
//#include <pcl/io/pcd_io.h>
//#include <pcl/point_cloud.h>
//#include <pcl/point_types.h>
//#include <pcl/filters/voxel_grid.h>
//#include <pcl/impl/point_types.hpp>
////#include <pcl/visualization/cloud_viewer.h>
//#include <pcl/features/normal_3d.h>
//#include <pcl/surface/gp3.h>
//
////****************************************
//// Had some errors here importing OpenNI properly earlier
////***
////#include <pcl/io/openni2_grabber.h>
////#include "NiTE.h"
//
////****************************************
//#include <pcl/console/print.h>
//#include <pcl/console/parse.h>
//#include <pcl/common/time.h>
//#include <pcl/console/time.h>
//#include <pcl/filters/passthrough.h>
//#include <pcl/compression/octree_pointcloud_compression.h>
//
//#include <stdio.h>
//#include <stdlib.h>
//
//#include <iostream>
//#include <vector>
//#include <sstream>
//
//#include <cstdlib>
//
//#include <boost/asio.hpp>
//#include <boost/thread/thread.hpp>
//
////****************************************
////******* Lib Freenect2 imports *********
//#include <libfreenect2/libfreenect2.hpp>
//#include <libfreenect2/frame_listener_impl.h>
//#include <libfreenect2/registration.h>
//#include <libfreenect2/packet_pipeline.h>
//#include <libfreenect2/logger.h>
////****************************************
//
////------
//// Lib OpenMP used for unrolling the depth and rgb data into cloud points
////THIS CODE USES freenect
////#include "freenect_grabber.hpp"
////***#include <omp.h>
////------
//
//
////We are going to turn to OpenCV to process the rgb/depth into cloud data
//#include "k2g.h"
//#include "serialization.h"
//
//
//
//
//using boost::asio::ip::tcp;
//using namespace pcl;
//using namespace pcl::octree;
//using namespace std;
////using namespace openni;
//
//const int kDistance = 7000;
//
//#define FPS_CALC(_WHAT_) \
//do \
//{ \
//static unsigned count = 0; \
//static double last = pcl::getTime(); \
//double now = pcl::getTime(); \
//++count; \
//if (now - last >= 1.0) \
//{ \
//std::cout << "Average framerate("<< _WHAT_ "); " << double(count)/double(now - last) << " Hz" << std::endl; \
//count = 0; \
//last = now; \
//} \
//}while(false)
//
//
//struct PointCloudBuffers
//{
//    typedef boost::shared_ptr<PointCloudBuffers> Ptr;
//    std::vector<short> points;
//    std::vector<unsigned char> rgb;
//};
//
//void CopyPointCloudToBuffers (pcl::PointCloud<pcl::PointXYZRGB>::ConstPtr cloud, PointCloudBuffers& cloud_buffers)
//{
//    const size_t nr_points = cloud->points.size ();
//    
//    cloud_buffers.points.resize (nr_points*3);
//    cloud_buffers.rgb.resize (nr_points*3);
//    
//    const pcl::PointXYZ  bounds_min (-0.9, -0.8, 1.0);
//    const pcl::PointXYZ  bounds_max (0.9, 3.0, 3.3);
//    
//    size_t j = 0;
//    for (size_t i = 0; i < nr_points; ++i)
//    {
//        
//        const pcl::PointXYZRGB& point = cloud->points[i];
//        
//        if (!pcl_isfinite (point.x) ||
//            !pcl_isfinite (point.y) ||
//            !pcl_isfinite (point.z))
//            continue;
//        
//        if (point.x < bounds_min.x ||
//            point.y < bounds_min.y ||
//            point.z < bounds_min.z ||
//            point.x > bounds_max.x ||
//            point.y > bounds_max.y ||
//            point.z > bounds_max.z)
//            continue;
//        
//        const int conversion_factor = 500;
//        
//        cloud_buffers.points[j*3 + 0] = static_cast<short> (point.x * conversion_factor);
//        cloud_buffers.points[j*3 + 1] = static_cast<short> (point.y * conversion_factor);
//        cloud_buffers.points[j*3 + 2] = static_cast<short> (point.z * conversion_factor);
//        
//        cloud_buffers.rgb[j*3 + 0] = point.r;
//        cloud_buffers.rgb[j*3 + 1] = point.g;
//        cloud_buffers.rgb[j*3 + 2] = point.b;
//        
//        j++;
//    }
//    
//    cloud_buffers.points.resize (j * 3);
//    cloud_buffers.rgb.resize (j * 3);
//}
//
//
//
//@interface FreenectPCL ()
//{
//    std::vector<uint16_t> depth_map;
//    std::vector<uint8_t> rgb;
//    
//    std::vector<uint16_t> m_buffer_depth;
//    std::vector<uint8_t> m_buffer_video;
//    std::vector<uint16_t> m_gamma;
//    
//    pcl::PassThrough<PointXYZRGBA> pass_;
//    pcl::io::OctreePointCloudCompression<PointXYZRGB>* octreeEncoder_;
//    pcl::io::compression_Profiles_e compressionProfile;
//    
//    bool showStatistics;
//    double pointResolution;
//    float octreeResolution;
//    bool doVoxelGridDownDownSampling;
//    unsigned int iFrameRate;
//    bool doColorEncoding;
//    unsigned int colorBitResolution;
//    
//    
//    bool protonect_shutdown;
//    tcp::iostream socketStream;
//    bool protonect_paused;
//    libfreenect2::Freenect2Device *devtopause;
//    
//
//    
//    int port_;
//    std::string device_id_;
//    boost::mutex mutex_;
//    pcl::PointCloud<PointXYZRGB>::Ptr filtered_cloud_;
//    PointCloudBuffers::Ptr buffers_;
//    
//    K2G k2g;//k2g(freenectprocessor);
//    //boost::shared_ptr<pcl::PointCloud<pcl::PointXYZRGB>> cloud;
//    pcl::PointCloud<PointXYZRGB>::Ptr cloud;
//    
//    cv::Mat color, depth;
//}
//
//
//@end
//
//@implementation FreenectPCL
//
///// Starts camera capture on main thread
//- (void) beginCapture
//{
//    dispatch_async(dispatch_get_main_queue(), ^{
//        [self startCameraCapture];
//    });
//}
//
//- (void) startCameraCapture
//{
//    printf("startCameraCapture\n");
//
//    //----------------------
//    //Processor freenectprocessor = OPENGL;
//    //----------------------
//    // test 1:
//    //works with pointer init
//    //k2g_objc = new K2G(freenectprocessor);
//    //----------------------
//    // test 2:
//    //K2G k2g_objc(freenectprocessor);
//    //----------------------
//    // test 3:
//    //K2G k2g(freenectprocessor);
//    //k2g_objc = k2g;
//    //boost::shared_ptr<pcl::PointCloud<pcl::PointXYZRGB>> cloud;
//    //----------------------
//    // removed visualization because it conflicts with Obj-c
//    //pcl::visualization::PointCloudColorHandlerRGBField<pcl::PointXYZRGB> rgb(cloud);
//    //----------------------
//    
//    std::cout << "getting cloud" << std::endl;
//    cloud = k2g.getCloud();
//    
//    k2g.printParameters();
//
//    k2g.get(color, depth, cloud);
//}
//
//- (boost::shared_ptr<pcl::PointCloud<pcl::PointXYZRGB>>) processCameraCloudFrame
//{
//    //printf("processing Frame\n");
//    
//    cloud = k2g.getCloud();
//    
//    /* Array traversal example
//    //Negative x,y transform
//    for (size_t i = 0; i < cloud->points.size(); ++i)
//    {
//        cloud->points[i].x = -cloud->points[i].x;
//        cloud->points[i].y = -cloud->points[i].y;
//        cloud->points[i].z = cloud->points[i].z;
//        cloud->points[i].r = cloud->points[i].r;
//        cloud->points[i].g = cloud->points[i].g;
//        cloud->points[i].b = cloud->points[i].b;
//     
//        //printf("(%f,%f,%f) - %hhu %hhu %hhu ", cloud->points[i].x, cloud->points[i].y, cloud->points[i].z, cloud->points[i].r, cloud->points[i].g, cloud->points[i].b);
//    }*/
//    
//    return cloud;
//}
//
//- (cv::Mat) processDepthCameraFrame
//{
//    //printf("processing Depth Frame\n");
//    k2g.getDepth(depth);
//    return depth;
//}
//
//- (cv::Mat ) processCameraFrame
//{
//    //printf("processing Frame\n");
//    k2g.getColor(color);
//    return color;
//}
//
//- (cv::Mat ) processCameraColorFrame
//{
//    //printf("processing Color Frame\n");
//    k2g.getColor(color);
//    return color;
//}
//
//
//- (void) closeCameraCapture
//{
//    printf("closeCameraCapture\n");
//    k2g.shutDown();
//}
//
//@end
//
////--------------------------------------------------------------
////  The following code demonstrates:
////      • Using an octree encoder
////      • Vending on a sockstream to a client
////      • Using a voxel grid
////      • Using Online compression profiles
////      • Initial (not working) fast-triangulation attempt
////      • pcl::viewer example
///*
//- (void) beginCapture_k2g
//{
//    std::string fileName = "pc_compressed.pcc";
//    std::string hostName = "localhost";
//    float min_v = 0.0f, max_v = 3.0f;
//    pass_.setFilterFieldName ("z");
//    pass_.setFilterLimits (min_v, max_v);
//    
//    
//    // default values
//    showStatistics = true;
//    pointResolution = 0.005;
//    octreeResolution = 0.01f;
//    doVoxelGridDownDownSampling = false;
//    iFrameRate = 30;
//    doColorEncoding = false;
//    colorBitResolution = 6;
//    compressionProfile = pcl::io::LOW_RES_ONLINE_COMPRESSION_WITH_COLOR;//pcl::io::MED_RES_OFFLINE_COMPRESSION_WITH_COLOR;
//    
//    
//    Processor freenectprocessor = OPENGL;
//    boost::shared_ptr<pcl::PointCloud<pcl::PointXYZRGB>> cloud;
//    K2G k2g(freenectprocessor);
//    std::cout << "getting cloud" << std::endl;
//    cloud = k2g.getCloud();
//    
//    k2g.printParameters();
//    
//    //Negative x transform
//    for (size_t i = 0; i < cloud->points.size (); ++i)
//    {
//        cloud->points[i].x = -cloud->points[i].x;
//        cloud->points[i].y = cloud->points[i].y;
//        cloud->points[i].z = cloud->points[i].z;
//        cloud->points[i].r = cloud->points[i].r;
//        cloud->points[i].g = cloud->points[i].g;
//        cloud->points[i].b = cloud->points[i].b;
//    }
//    
//    cloud->sensor_orientation_.w() = 0.0;
//    cloud->sensor_orientation_.x() = 0.0;
//    cloud->sensor_orientation_.y() = 0.0;
//    cloud->sensor_orientation_.z() = 1.0;
//    
//    //-----
//    //REMOVE ME... voxel grid filter is replaced with the octreeEncoder.. OR NOT?>!>
//    pcl::VoxelGrid<PointXYZRGB> voxel_grid_filter_;
//    float leaf_size_x = 0.005; //0.01 is a good filter size... 0.001 is very detailed... 0.1 is very bulky
//    float leaf_size_y = 0.005;
//    float leaf_size_z = 0.005;
//    voxel_grid_filter_.setLeafSize (leaf_size_x, leaf_size_y, leaf_size_z);
//    //-----
//    octreeEncoder_ = new pcl::io::OctreePointCloudCompression<PointXYZRGB> (compressionProfile, showStatistics, pointResolution,
//                                                                            octreeResolution, doVoxelGridDownDownSampling, iFrameRate,
//                                                                            doColorEncoding, static_cast<unsigned char> (colorBitResolution));
//    
//    
//    // switch to ONLINE profiles
//    if (compressionProfile == pcl::io::LOW_RES_OFFLINE_COMPRESSION_WITH_COLOR)
//        compressionProfile = pcl::io::LOW_RES_ONLINE_COMPRESSION_WITH_COLOR;
//    else if (compressionProfile == pcl::io::LOW_RES_OFFLINE_COMPRESSION_WITHOUT_COLOR)
//        compressionProfile = pcl::io::LOW_RES_ONLINE_COMPRESSION_WITHOUT_COLOR;
//    else if (compressionProfile == pcl::io::MED_RES_OFFLINE_COMPRESSION_WITH_COLOR)
//        compressionProfile = pcl::io::MED_RES_ONLINE_COMPRESSION_WITH_COLOR;
//    else if (compressionProfile == pcl::io::MED_RES_OFFLINE_COMPRESSION_WITHOUT_COLOR)
//        compressionProfile = pcl::io::MED_RES_ONLINE_COMPRESSION_WITHOUT_COLOR;
//    else if (compressionProfile == pcl::io::HIGH_RES_OFFLINE_COMPRESSION_WITH_COLOR)
//        compressionProfile = pcl::io::HIGH_RES_ONLINE_COMPRESSION_WITH_COLOR;
//    else if (compressionProfile == pcl::io::HIGH_RES_OFFLINE_COMPRESSION_WITHOUT_COLOR)
//        compressionProfile = pcl::io::HIGH_RES_ONLINE_COMPRESSION_WITHOUT_COLOR;
//    //-----
//    
//    
//    boost::shared_ptr<pcl::visualization::PCLVisualizer> viewer(new pcl::visualization::PCLVisualizer ("3D Viewer"));
//    viewer->setBackgroundColor (0, 0, 0);
//    pcl::visualization::PointCloudColorHandlerRGBField<pcl::PointXYZRGB> rgb(cloud);
//    viewer->addPointCloud<pcl::PointXYZRGB>(cloud, rgb, "sample cloud");
//    viewer->setPointCloudRenderingProperties(pcl::visualization::PCL_VISUALIZER_POINT_SIZE, 2, "sample cloud");
//    viewer->initCameraParameters ();
//    //viewer->addCoordinateSystem (1.0);
//
//    //viewer->setShapeRenderingProperties(pcl::visualization::PCL_VISUALIZER_REPRESENTATION,
//    //                                                       pcl::visualization::PCL_VISUALIZER_REPRESENTATION_SURFACE, "cylinder");
//    
//    
//    
//    
//    //***** BEGIN FAST TRIANGULATION ***** ...Needs debugging... it is complaining of empty inupt tree for KDTree initializers
//    //*
//    //Step0: prepare XYZ cloud from XYZRGB cloud <---- directly capture the cloud into XYZ!>?!? then send data for lightfield? with texture coords might be ridiculously large amount of data
//    PointCloud<PointXYZ> cloud_xyz;
//    for (size_t i = 0; i < cloud_xyz.points.size(); i++) {
//        cloud_xyz.points[i].x = cloud->points[i].x;
//        cloud_xyz.points[i].y = cloud->points[i].y;
//        cloud_xyz.points[i].z = cloud->points[i].z;
//    }
//    
//    //Step1: Normal Estimation
//    pcl::NormalEstimation<pcl::PointXYZ, pcl::Normal> n;
//    pcl::PointCloud<pcl::Normal>::Ptr normals (new pcl::PointCloud<pcl::Normal>);
//    pcl::search::KdTree<pcl::PointXYZ>::Ptr tree (new pcl::search::KdTree<pcl::PointXYZ>);
//    tree->setInputCloud(cloud_xyz.makeShared());
//    n.setInputCloud(cloud_xyz.makeShared());
//    n.setSearchMethod(tree);
//    n.setKSearch(20);
//    n.compute(*normals);
//    //Step2: concatenate XYZ and Normal Fields
//    pcl::PointCloud<pcl::PointNormal>::Ptr cloud_with_normals (new pcl::PointCloud<pcl::PointNormal>);
//        //cloud_with_normals = cloud_xyz + normals
//    pcl::concatenateFields(*(cloud_xyz.makeShared()), *(normals->makeShared()), *(cloud_with_normals->makeShared()));
//    //Step3: create search tree
//    pcl::search::KdTree<pcl::PointNormal>::Ptr tree2 (new pcl::search::KdTree<pcl::PointNormal>);
//    tree2->setInputCloud(cloud_with_normals);
//    
//    //Step4: initialize objects
//    
//    pcl::GreedyProjectionTriangulation<pcl::PointNormal> gp3;
//    pcl::PolygonMesh triangles;
//    
//    gp3.setSearchRadius(0.025);
//    
//    gp3.setMu(2.5);
//    gp3.setMaximumNearestNeighbors(100);
//    gp3.setMaximumSurfaceAngle(M_PI/4);
//    gp3.setMinimumAngle(M_PI/18);
//    gp3.setMaximumAngle(2*M_PI/3);
//    gp3.setNormalConsistency(false);
//    
//    gp3.setInputCloud(cloud_with_normals);
//    gp3.setSearchMethod(tree2);
//    gp3.reconstruct(triangles);
//    
//    std::vector<int> parts = gp3.getPartIDs();
//    std::vector<int> states = gp3.getPointStates();
//    
//    viewer->addPolygonMesh(triangles);
//    //* /
//    //*****  END TRIANGULATION  *****
//    
//    
//    cv::Mat color, depth;
//    size_t framecount = 0;
//    
//    pcl::PointCloud<PointXYZRGB>::Ptr temp_cloud (new pcl::PointCloud<PointXYZRGB>);
//    PointCloudBuffers::Ptr new_buffers = PointCloudBuffers::Ptr (new PointCloudBuffers); //Check for deprications
//    
//    
//    
//    //---- Begin server streaming
//    
//    //TODO: this needs to be on a secondary thread...
//    
//    port_ = 11111;
//    boost::asio::io_service io_service;
//    tcp::endpoint endpoint (tcp::v4 (), static_cast<unsigned short> (port_));
//    tcp::acceptor acceptor (io_service, endpoint);
//    tcp::socket socket (io_service);
//    
//    
//    std::cout << "Listening on port " << port_ << "..." << std::endl;
//    
//    
//    //acceptor.accept (*socketStream.rdbuf ());// *** CONTROLS THE SERVER CODE TO TURN ON ***
//    std::cout << "Client connected." << std::endl;
//    
//    
//    //
//    
//    
//    
//    //TODO SERVER SEND THIS STUFF1!!!
//    //socketStream; //FIX ME: this should be a pointer to the output file or the socket stream... in my case its always the socket stream until IM ready to output data in a file
//    
//    
//    //---
//    int doOnce = 0;
//    
//    while(!viewer->wasStopped() ){
//    
//        
//        viewer->spinOnce ();
//        std::chrono::high_resolution_clock::time_point tnow = std::chrono::high_resolution_clock::now();
//        
//        k2g.get(color, depth, cloud);
//        // Showing only color since depth is float and needs conversion
//        
//        
//        //Negative x transform
//        for (size_t i = 0; i < cloud->points.size (); ++i)
//        {
//            cloud->points[i].x = -cloud->points[i].x;
//            cloud->points[i].y = cloud->points[i].y;
//            cloud->points[i].z = cloud->points[i].z;
//            cloud->points[i].r = cloud->points[i].r;
//            cloud->points[i].g = cloud->points[i].g;
//            cloud->points[i].b = cloud->points[i].b;
//        }
//        framecount++;
//        
//        
//        //------------------------------------
//        // use frame
//        
//        //Spit out a file every 2 seconds.. thats a keyframe thing and will
//        //be a static point cloud.... instead... record the stream over the network and make that
//        //binary stream the GLS 2 second stream... along with positional keyframed audio and video atlas?
//        //unless the video atlas lightfield stuff gets coded later in an additional release...
//        //first we do just color encoded points then we do lightfield reconstructions
//        if (framecount % 2000 == 0)
//        {
//            std::cout << " Recieved " << framecount << " frames. Ctrl-C to stop." << std::endl;
//            //pcl::io::savePCDFileASCII ("test_pcd.pcd", &cloud);
//            //Pinch off the stream file here and start another file.... GLS 2 second intervals for recording
//        }
//        
//        
//        
//        //int c = cv::waitKey(1);
//        
//        std::chrono::high_resolution_clock::time_point tpost = std::chrono::high_resolution_clock::now();
//        std::cout << "delta " << std::chrono::duration_cast<std::chrono::duration<double>>(tpost-tnow).count() * 1000 << std::endl;
//        
//        //--- Filter and Stream cloud data
//        voxel_grid_filter_.setInputCloud (cloud);
//        voxel_grid_filter_.filter (*temp_cloud);
//        
//        //Example of filtering by the z axis.... using min_v and max_v
//        //pass_.setFilterFieldName (field_name);
//        //pass_.setFilterLimits (min_v, max_v);
//        
//        
//        
//        //TODO: server stream me
//        octreeEncoder_->encodePointCloud (temp_cloud, socketStream); //SEND THE BINARY OUTPUT STREAM
//        
//        
//        
//        pcl::visualization::PointCloudColorHandlerRGBField<pcl::PointXYZRGB> rgb2(temp_cloud);
//        viewer->updatePointCloud<pcl::PointXYZRGB> (temp_cloud, rgb2, "sample cloud");
//        
//    }
//    
//    k2g.shutDown();
//}
//*/
////--------------------------------------------------------------
