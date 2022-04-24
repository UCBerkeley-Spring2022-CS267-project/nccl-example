
#include <string>
#include <vector>
#include <cstdlib> // std::getenv
#include <stdexcept> // std::runtime_error
#include "blinkplus.h"

  #define CUDACHECK(cmd) do {                         \
    cudaError_t e = cmd;                              \
    if( e != cudaSuccess ) {                          \
      printf("Failed: Cuda error %s:%d '%s'\n",       \
          __FILE__,__LINE__,cudaGetErrorString(e));   \
      exit(EXIT_FAILURE);                             \
    }                                                 \
  } while(0)
  
  
  #define NCCLCHECK(cmd) do {                         \
    ncclResult_t r = cmd;                             \
    if (r!= ncclSuccess) {                            \
      printf("Failed, NCCL error %s:%d '%s'\n",       \
          __FILE__,__LINE__,ncclGetErrorString(r));   \
      exit(EXIT_FAILURE);                             \
    }                                                 \
  } while(0)

struct blinkplusHelperGroup
{
    std::vector<int> devs;
    std::vector<ncclComm_t> comms;
    std::vector<int*> sendbuff;
    std::vector<int*> recvbuff;
    std::vector<cudaStream_t> streams;
    std::string graph_filepath;
    int num_comms;

    blinkplusHelperGroup( const char* graph_filepath_cstr, std::vector<int> devs )
    {
        if ( std::getenv(graph_filepath_cstr) == nullptr )
        {
            throw std::runtime_error("NCCL_GRAPH_FILE_CHAIN_XXX unset\b");
        }
        this->graph_filepath = std::getenv(graph_filepath_cstr);

        this->devs = devs;
        this->comms.resize( this->devs.size() );
        this->sendbuff.resize( this->devs.size() );
        this->recvbuff.resize( this->devs.size() );
        this->streams.resize( this->devs.size() );
        this->num_comms = this->devs.size();
    }
};

// TODO improve this
std::vector<blinkplusHelperGroup> blinkplusHelperGroupsContainer;

#define BLINKPLUS_BUFFER_SIZE_BYTES 100000000 // 1GB

// NCCL_API(ncclResult_t, blinkplusGetHelperCnt, ncclComm_t* comms, int ndev, const int *devlist, int* helper_cnt );
ncclResult_t blinkplusGetHelperCnt( ncclComm_t* comm, int ndev, const int *devlist, int* helper_cnt )
{
  *helper_cnt = 3;
}


// NCCL_API(ncclResult_t, blinkplusCommInitAll, ncclComm_t* comms, int ndev, const int* devlist, int numBlinkplusHelperGroup );
ncclResult_t blinkplusCommInitAll( ncclComm_t* comms, int ndev, const int *devlist, int numBlinkplusHelperGroup )
{
  // Currently, lots of support is hardcoded
  if (ndev != 2 ) 
  {
    //WARN("Invalid device count requested : %d, need 2", ndev);
    return ncclInvalidArgument;
  }

  if ( numBlinkplusHelperGroup != 3 )
  {
    //WARN("Invalid helper group requested : %d, need 3", numBlinkplusHelperGroup );
    return ncclInvalidArgument;
  }

  // Create blink+ helper group
  // return its corresbonding error code
  blinkplusHelperGroupsContainer.clear();
  blinkplusHelperGroupsContainer.reserve( 3 );
  setenv( "NCCL_PROTO", "Simple", 1);
  setenv( "NCCL_ALGO", "Tree", 1 );

  blinkplusHelperGroupsContainer.emplace_back( "NCCL_GRAPH_FILE_CHAIN_021", std::vector<int>{0,2,1} );
  blinkplusHelperGroupsContainer.emplace_back( "NCCL_GRAPH_FILE_CHAIN_031", std::vector<int>{0,3,1} );
  blinkplusHelperGroupsContainer.emplace_back( "NCCL_GRAPH_FILE_CHAIN_0321", std::vector<int>{0,3,2,1} );

  // Save user graph file for later use
  std::string userGraphFile;
  if ( std::getenv("NCCL_GRAPH_FILE") != nullptr )
  {
    userGraphFile = std::string( std::getenv("NCCL_GRAPH_FILE") );
  }

  // Create user helper group
  for ( int group_i = 0; group_i < blinkplusHelperGroupsContainer.size(); ++group_i )
  {
    #define helperGroupI( i ) blinkplusHelperGroupsContainer.at( i )
  
    // Allocate memory buffer & stream
    for ( int comm_j = 0; comm_j < helperGroupI( group_i ).num_comms; comm_j++ )
    {
      // Check if use user buffer or not. 
      // User will provide buffer at runtime
      bool use_user_buffer = false;
      for ( int user_dev_k = 0; user_dev_k < ndev; ++user_dev_k )
      {
        if ( devlist[ user_dev_k ] == helperGroupI( group_i ).devs[ comm_j ] )
        {
          use_user_buffer = true;
          break;
        }
      }

      // Use our internal buffer
      CUDACHECK(cudaSetDevice( helperGroupI( group_i ).devs[ comm_j ] ));
      if ( !use_user_buffer )
      {
        CUDACHECK(cudaMalloc( &(helperGroupI( group_i ).sendbuff.at( comm_j )), BLINKPLUS_BUFFER_SIZE_BYTES ));
        CUDACHECK(cudaMalloc( &(helperGroupI( group_i ).recvbuff.at( comm_j )), BLINKPLUS_BUFFER_SIZE_BYTES ));
        CUDACHECK(cudaMemset(   helperGroupI( group_i ).sendbuff.at( comm_j ), 0, BLINKPLUS_BUFFER_SIZE_BYTES ));
        CUDACHECK(cudaMemset(   helperGroupI( group_i ).recvbuff.at( comm_j ), 0, BLINKPLUS_BUFFER_SIZE_BYTES ));
      }
      // set nullptr for safety
      else
      {
        helperGroupI( group_i ).sendbuff.at( comm_j ) = nullptr;
        helperGroupI( group_i ).recvbuff.at( comm_j ) = nullptr;
      }
      CUDACHECK(cudaStreamCreate( &(helperGroupI( group_i ).streams.at( comm_j )) ));
    } // end for each comm/dev inside group


    // Initialize communicator
    setenv( "NCCL_GRAPH_FILE", helperGroupI( group_i ).graph_filepath.c_str() , 1 );
    NCCLCHECK( ncclCommInitAll( helperGroupI( group_i ).comms.data(), \
                                helperGroupI( group_i ).num_comms, \
                                helperGroupI( group_i ).devs.data() ) );

    #undef helperGroupI
  } // end for each helper group

  // Unset NCCL graph file
  if ( !userGraphFile.empty() )
  {
    setenv( "NCCL_GRAPH_FILE", userGraphFile.c_str(), 1 );
  }
} // end of blinkplusCommInitAll


// NCCL_API(ncclResult_t, blinkplusCommDestroy, ncclComm_t* comms );
ncclResult_t  blinkplusCommDestroy( ncclComm_t* comms )
{
  for ( int group_i = 0; group_i < blinkplusHelperGroupsContainer.size(); ++group_i )
  {
    #define helperGroupI( i ) blinkplusHelperGroupsContainer.at( i )
  
    // Allocate memory buffer & stream
    for ( int comm_j = 0; comm_j < helperGroupI( group_i ).num_comms; comm_j++ )
    {
      ncclCommDestroy( helperGroupI( group_i ).comms.at( comm_j ) );
    } // end for each comm/dev inside group

    #undef helperGroupI
  } // end for each helper group
} // end of blinkplusCommDestroy


//NCCL_API(ncclResult_t, blinkplusBroadcast, ncclComm_t* comms, int ndev, const int* devlist, \
  const void*** sendbuff, void*** recvbuff, int* count, ncclDataType_t datatype, int root );
ncclResult_t  blinkplusBroadcast( ncclComm_t* comms, int ndev, const int *devlist, \
    const void*** sendbuff, void*** recvbuff, int* count, ncclDataType_t datatype, int root )
{
  // Start broadcast for each group
  for ( int group_i = 0; group_i < blinkplusHelperGroupsContainer.size(); ++group_i )
  {
    NCCLCHECK(ncclGroupStart());
    #define helperGroupI( i ) blinkplusHelperGroupsContainer.at( i )
  
    // Check if user user buffer or own buffer
    for ( int comm_j = 0; comm_j < helperGroupI( group_i ).num_comms; comm_j++ )
    {
      bool use_user_buffer = false;
      for ( int user_dev_k = 0; user_dev_k < ndev; ++user_dev_k )
      {
        if ( devlist[ user_dev_k ] == helperGroupI( group_i ).devs[ comm_j ] )
        {
          use_user_buffer = true;
          NCCLCHECK(ncclBroadcast((const void*)sendbuff[ group_i ][ user_dev_k ], \
                                  (void*)recvbuff[ group_i ][ user_dev_k ], \
                                  count[ group_i ], datatype, root, \
                                  helperGroupI( group_i ).comms.at( comm_j ), \
                                  helperGroupI( group_i ).streams.at( comm_j )));
          break;
        }
      }

      if ( !use_user_buffer )
      {
        NCCLCHECK(ncclBroadcast((const void*)helperGroupI( group_i ).sendbuff.at( comm_j ), \
                                (void*)helperGroupI( group_i ).recvbuff.at( comm_j ), \
                                count[ group_i ], datatype, root, \
                                helperGroupI( group_i ).comms.at( comm_j ), \
                                helperGroupI( group_i ).streams.at( comm_j ) ));
      }
    } // end for each comm/dev inside group

    #undef helperGroupI

    NCCLCHECK(ncclGroupEnd());
  } // end for each helper group
}


// NCCL_API(ncclResult_t, blinkplusAllReduce, ncclComm_t* comms, int ndev, const int* devlist, \
  const void*** sendbuff, void*** recvbuff, int* count, ncclDataType_t datatype, ncclRedOp_t op );
ncclResult_t  blinkplusAllReduce( ncclComm_t* comms, int ndev, const int *devlist, \
    const void*** sendbuff, void*** recvbuff, int* count, ncclDataType_t datatype, ncclRedOp_t op )
{
  // Start all reduce for each group
  for ( int group_i = 0; group_i < blinkplusHelperGroupsContainer.size(); ++group_i )
  {
    NCCLCHECK(ncclGroupStart());

    #define helperGroupI( i ) blinkplusHelperGroupsContainer.at( i )
  
    // Check if user user buffer or own buffer
    for ( int comm_j = 0; comm_j < helperGroupI( group_i ).num_comms; comm_j++ )
    {
      bool use_user_buffer = false;
      for ( int user_dev_k = 0; user_dev_k < ndev; ++user_dev_k )
      {
        if ( devlist[ user_dev_k ] == helperGroupI( group_i ).devs[ comm_j ] )
        {
          use_user_buffer = true;
          NCCLCHECK(ncclAllReduce((const void*)sendbuff[ group_i ][ user_dev_k ], \
                                  (void*)recvbuff[ group_i ][ user_dev_k ], \
                                  count[ group_i ], datatype, op, \
                                  helperGroupI( group_i ).comms.at( comm_j ), \
                                  helperGroupI( group_i ).streams.at( comm_j )));
          break;
        }
      }

      if ( !use_user_buffer )
      {
        NCCLCHECK(ncclAllReduce((const void*)helperGroupI( group_i ).sendbuff.at( comm_j ), \
                                (void*)helperGroupI( group_i ).recvbuff.at( comm_j ), \
                                count[ group_i ], datatype, op, \
                                helperGroupI( group_i ).comms.at( comm_j ), \
                                helperGroupI( group_i ).streams.at( comm_j ) ));
      }
    } // end for each comm/dev inside group

    #undef helperGroupI

    NCCLCHECK(ncclGroupEnd());
  } // end for each helper group
}


// NCCL_API(ncclResult_t, blinkplusStreamSynchronize, ncclComm_t* comms );
ncclResult_t blinkplusStreamSynchronize( ncclComm_t* comms )
{
  for ( int group_i = 0; group_i < blinkplusHelperGroupsContainer.size(); ++group_i )
  {
    #define helperGroupI( i ) blinkplusHelperGroupsContainer.at( i )
  
    // Synchronize for every communicator
    for ( int comm_j = 0; comm_j < helperGroupI( group_i ).num_comms; comm_j++ )
    {
        CUDACHECK(cudaSetDevice( helperGroupI( group_i ).devs.at( comm_j ) ));
        CUDACHECK(cudaStreamSynchronize( helperGroupI( group_i ).streams.at( comm_j ) ));
    } // end for each comm/dev inside group

    #undef helperGroupI
  } // end for each helper group
}

#undef CUDACHECK
#undef NCCLCHECK